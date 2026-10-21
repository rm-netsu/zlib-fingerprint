# zlib-fingerprint

Identify the compressor implementation, version and parameter set that
produced a zlib (RFC 1950) stream — by bit-exact brute force.

Given a zlib stream, the tool decompresses it, extracts the header
metadata, and then re-compresses the payload with known compressor
implementations and parameter combinations until one of them reproduces
the original stream **byte for byte**.

## How the search works

The enumeration order is driven by the stream's own metadata, which is
what makes convergence fast. The naive approach (a fixed "popular
parameters" probe, then a full parameter matrix hard-coded to
`windowBits=15`, then a blind `windowBits` sweep) wastes hundreds to
thousands of attempts on combinations that provably cannot match.
This tool uses three metadata-guided stages instead:

### Metadata hints taken from the header

| Hint | Meaning | How it is used |
|------|---------|----------------|
| `CINFO` (CMF >> 4) | windowBits used by the producer (`CINFO + 8`) | Fixes `windowBits` for stages 1–2; any other window cannot reproduce the header bytes |
| `FLEVEL` (FLG >> 6) | level/strategy class written by zlib's `deflate.c` | Reorders level probes: FLEVEL=2 → level 6 first, FLEVEL=3 → 9, 8, 7, FLEVEL=1 → 5..2, FLEVEL=0 → level 1 + huffman-only/rle/fixed strategies |
| `FDICT` (FLG bit 5) | preset dictionary | Streams with a preset dictionary are reported as not reproducible without the exact dictionary |
| `FCHECK` validity | canonical header vs custom writer | Non-canonical headers enable the stage-3 window sweep; canonical headers prove the sweep pointless |
| First DEFLATE block `BTYPE` | stored / fixed / dynamic | A stored first block schedules a level-0 probe at the front |
| Stream sizes | compressed vs uncompressed | Level 0 (stored) candidates are skipped when the compressed stream is too small to be stored |

### Header prediction

Every zlib-family implementation writes `CMF`/`FLG` deterministically
from `(windowBits, level, strategy)`:

```
FLEVEL = 0 if strategy >= Z_HUFFMAN_ONLY or level < 2
       = 1 if level < 6
       = 2 if level == 6
       = 3 otherwise
```

The engine predicts the two header bytes each candidate would emit and
**skips every candidate whose predicted header differs from the observed
one**. Implementations with fixed header layouts are handled the same
way (all mappings verified empirically, see `src/hints.zig`):

| Implementation | Header behavior |
|----------------|-----------------|
| integrated engine | writes exactly the stock zlib header for its parameters |
| Zopfli `--zlib` | always `0x78 0xDA` (FLEVEL=3); note `--deflate` produces raw deflate and can never match a zlib stream |
| libdeflate 1.20 | fixed CINFO=7; FLEVEL: 1 → 0, 2–5 → 1, 6–7 → 2, 8–12 → 3 |
| miniz 3.1.2 | fixed CINFO=7; FLEVEL: 1 → 0, 2–5 → 1, 6 → 2, 7–10 → 3 |
| advdef | header depends on the backend; treated as unpredictable, tried last |

### Stages

1. **Metadata-guided pass** — one to five probes per implementation whose
   predicted header matches exactly. A stream produced by
   `zlib.compress(..., 6)` (the default) matches on the very first attempt.
2. **Full parameter matrix, trusted window** — all remaining
   `(level, memLevel, strategy)` combinations whose FLEVEL class matches
   the header, at `windowBits = CINFO + 8`, ordered by proximity to the
   hinted class. Zopfli iterations and the libdeflate/miniz level ranges
   run here, filtered by their header mappings.
3. **windowBits distrust sweep** — only when the header is non-canonical
   (invalid FCHECK, CINFO=0) or when `--paranoid` is passed. With a
   canonical header a differing windowBits emits different header bytes,
   so the sweep is provably useless and is skipped with an explanation.

Duplicate candidates across stages are eliminated through a visited set.

## The integrated zlib engine

By default, stock zlib candidates are **not** spawned as binaries: they
are re-compressed in-process by `src/deflate/` — a bit-exact
reimplementation of historical zlib deflate covering every stock release
**1.2.3 – 1.3.1**. Mismatching candidates abort at the first divergent
output chunk, which keeps the full matrix fast (thousands of attempts per
second even on multi-hundred-KB inputs).

### Where the output actually changed (1.2.3 → 1.3.1)

Established by diffing every release and by a ~29 000-combination
differential matrix over 13 compiled historical versions:

1. **`deflate_stored` / level 0 — three generations**
   (`stored_legacy.zig` → `stored_1_2_9.zig` → `stored.zig`);
   1.2.9 additionally emits no final block for empty input.
2. **`Z_RLE` (strategy 3)** — 1.2.3 uses `deflate_fast`/`deflate_slow` with
   `longest_match_fast`; 1.2.4+ has the dedicated `deflate_rle` (`rle.zig`).
3. **`Z_HUFFMAN_ONLY` (strategy 2)** — 1.2.3 disables the match search
   inside `deflate_fast`/`deflate_slow`; 1.2.4+ has the dedicated
   `deflate_huff` (`huff.zig`) whose fill_window timing can shift block
   boundaries.
4. **`deflate_fast`/`deflate_slow` internals** — strategy checks live
   inside the functions in 1.2.3 (`fast_1_2_3.zig` / `slow_1_2_3.zig`).

Everything else — `longest_match`, `fill_window`, the whole `trees.c`
Huffman machinery, tables, adler32, stream framing — is byte-identical
across the entire range and lives in shared modules only.

### Output-equivalence classes

```text
{ 1.2.3 }  { 1.2.4-1.2.8 }  { 1.2.9 }  { 1.2.10-1.3.1 }
```

The search tries the minimal set of representatives per parameter
combination (`collapseGroups`): one for most combinations, two for
Z_HUFFMAN_ONLY / Z_RLE (1.2.3 vs 1.2.4+ block states) and up to four at
level 0 (three stored-block generations). A match is reported with the
honest version range the representative reproduces, e.g.
`level=6, memLevel=8, strategy=default, windowBits=15, zlib 1.2.3-1.3.1`.

### Producer semantics

The integrated engine models the **one-shot** call pattern (the whole
payload, a single `Z_FINISH`), mirroring the most common producers
(`zlib.compress` in Python, `deflateSync` in Node) and the bundled
wrapper binaries. This matters for level 0: the stored-block layout of
modern zlib depends on both the flush pattern and the output buffer
size, so the level-0 path drains the output in a single call. Levels
1-9 are call-pattern-neutral.

### Known divergence from real zlib (documented UB)

Running `deflate_huff`/`deflate_rle` **at level 0** with zlib 1.2.4-1.2.8
triggers `_tr_flush_block`'s `level == 0 -> force a stored block` branch
far beyond zlib's own pending buffer. Genuine zlib 1.2.4-1.2.8
heap-overflows there and emits a corrupted stream (verified with
AddressSanitizer against the unmodified C sources). The search visits
that path only in the stage-3 sweep, and this port models the idealized
(valid) stream the code path would produce.

## Supported implementations

| Profile | Type | Parameters |
|---------|------|------------|
| zlib (integrated), 1.2.3 – 1.3.1 | in-process | full `level memLevel strategy windowBits` matrix |
| zlib 1.3.2 | external binary | `level memLevel strategy windowBits` |
| zlib 1.2.3 / 1.2.5 / 1.2.7 / 1.2.8 / 1.2.11 / 1.2.12 / 1.2.13 / 1.3 / 1.3.1 | external binaries | same; skipped in the default mode (covered bit-exactly by the integrated engine), enabled by `--external-zlib` |
| zlib-ng 2.2.1 (compat) | external binary | `level memLevel strategy`, windowBits fixed to 15 |
| Zopfli 1.0.3 | external binary | `--zlib -c --iN <file>`; header is always `0x78 0xDA` |
| libdeflate 1.20 | external binary | `level` (1–12) |
| miniz 3.1.2 | external binary | `level` (1–10) |
| AdvanceCOMP 2.6 advdef | external binary | `-L -z -k` on a temp file; last resort |

Missing binaries are detected once up front and their profiles are
skipped. Without any binaries at all, the tool still fingerprints every
stock zlib 1.2.3–1.3.1 stream.

The external zlib wrappers compress **one-shot** (read all input, single
`Z_FINISH`), matching the integrated engine's producer model. Even so,
some producers are outside the profile set — e.g. the CPython builds
shipped by python-build-standalone link their own zlib build whose
level-0 block layout differs from stock zlib; such streams are reported
honestly as "no match".

## Building

Requires [Zig 0.16.0](https://ziglang.org/download/).

```sh
zig build -Doptimize=ReleaseFast
# Windows cross-compilation:
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu
zig build test          # unit tests
```

Artifacts land in `zig-out/bin/`: `zlib-fingerprint` (the CLI) and
`zcompress` (dev tool: compress stdin exactly like a specific historical
zlib release — the differential-verification harness for the integrated
engine).

The optional external compressor binaries are built once by:

```sh
cd binaries && ./build-binaries.sh
```

## Usage

```sh
./zig-out/bin/zlib-fingerprint [--verbose] [--no-color] [--paranoid] \
    [--external-zlib] [--binaries <dir>] <stream.zlib>
```

* `--external-zlib` — spawn the per-version zlib wrapper binaries for
  stock zlib candidates instead of the integrated engine (the original
  tool's behavior; useful for cross-checking).
* `--paranoid` — force the stage-3 windowBits sweep even for canonical
  headers.

Exit codes: `0` — bit-exact match found; `1` — no match or failure;
`2` — usage error.

Example (default-level stream produced by Python's zlib):

```text
=== Zlib Header Metadata (RFC 1950) ===
- Header Valid (FCHECK) : Yes (OK)
- Compression Method    : 8 (deflate)
- Window Size           : 32768 bytes (windowBits = 15)
- Preset Dictionary     : None
- Compression Level Hint: default algorithm (FLEVEL = 2)
- Header Class          : canonical (produced by a stock zlib-family implementation)
- First DEFLATE Block   : BFINAL=1, BTYPE=2 (Dynamic Huffman)
- Sizes                 : 36 -> 64 bytes
=======================================

Metadata-driven search plan:
- FLEVEL=2  -> probing level 6 (default) first
- windowBits fixed to CINFO+8 = 15 while the header stays trusted

Mode: integrated zlib 1.2.3-1.3.1 engine + external alternatives (7/16 available)

==> Stage 1: metadata-guided pass (6 candidates)

[SUCCESS] Bit-exact match found!
- Implementation: zlib (integrated)
- Stage         : Stage 1: metadata-guided pass
- Parameters    : level=6, memLevel=8, strategy=default, windowBits=15
- Versions      : zlib 1.2.3-1.3.1 (integrated engine)
- Convergence   : 1 attempt, 10 ms
```

With `--verbose` / `-v` every attempt is logged (the bracketed suffix
names the covered zlib version range for the current parameter
combination):

```text
  [attempt     1] P1 zlib (integrated) | lvl=6 mem=8 strat=default wBits=15 [zlib 1.2.3-1.3.1] -> MATCH
```

## Measured convergence

23 generated fixtures + real-world streams, attempt counts until the
bit-exact match (lower is better). The naive three-phase order is the
original TypeScript tool; "v1.1" is the metadata-driven engine with
external zlib binaries; "v2.0" additionally collapses stock-zlib
candidates into integrated in-process representatives:

| Stream | FLEVEL | naive | v1.1 | v2.0 |
|--------|--------|------:|-----:|-----:|
| default level 6 (`0x789C`) | 2 | 104 | **1** | **1** |
| level 9 (`0x78DA`) | 3 | 29 | **1** | **1** |
| level 1 (`0x7801`) | 0 | 1 | **1** | **1** |
| stored (level 0) | 0 | no match (12632 wasted) | 1 | **2** |
| windowBits 12 (`0x4889`) | 2 | 2133 | **1** | **1** |
| huffman-only strategy | 0 | 31 | 3 | **3** |
| rle strategy | 0 | 32 | 4 | **5** |
| fixed strategy | 0 | 108 | 76 | **54** |
| filtered strategy | 2 | 105 | 15 | **7** |
| memLevel 9 | 2 | 109 | 16 | **8** |
| zlib-ng default | 2 | 325 | 11 | **3** |
| libdeflate level 6 | 2 | 486 | 12 | **4** |
| miniz level 10 | 3 | 502 | 42 | **18** |
| Zopfli 15 iterations | 3 | impossible | 48 | **24** |

v2.0 keeps the metadata-guided order and removes process spawns from the
zlib-family path entirely: a stock zlib stream is fingerprinted with a
single in-process compression (~10 ms cold start included).

## Project structure

```text
src/
├── main.zig           # CLI: RFC 1950 analysis, inflate, search plan, report
├── fingerprint.zig    # 3-stage metadata-driven search + candidate executors
├── hints.zig          # header parsing, FLEVEL mapping, header prediction
├── profiles.zig       # implementation table (priorities, integrated coverage)
├── ui.zig             # SGR colors + live progress
└── deflate/           # integrated historical zlib engine
    ├── deflate.zig    # version registry (13 releases / 4 classes), dispatch,
    │                  # one-shot compressor with early-abort comparison
    ├── state.zig      # shared deflate_state, bit output, window, hash,
    │                  # longest_match, longest_match_fast (1.2.3-only paths)
    ├── tables.zig     # configuration_table, static trees, length/distance codes
    ├── trees.zig      # shared trees.c: block flush, tree building, codes
    ├── stored_legacy.zig  # deflate_stored, zlib 1.2.3-1.2.8  ┐ version-specific
    ├── stored_1_2_9.zig   # deflate_stored, zlib 1.2.9         ├─ generations
    ├── stored.zig         # deflate_stored, zlib 1.2.10-1.3.1  ┘
    ├── fast.zig / slow.zig          # deflate_fast/slow, zlib 1.2.4+
    ├── fast_1_2_3.zig / slow_1_2_3.zig  # 1.2.3 variants (strategy dispatch inside)
    ├── rle.zig        # deflate_rle,   zlib 1.2.4+
    └── huff.zig       # deflate_huff,  zlib 1.2.4+
tools/
└── zcompress.zig      # dev tool: stdin -> stdout like zlib-<version> wrappers
scripts/
├── gen_fixtures.py    # benchmark fixture generator
├── gen_edge.py        # FDICT / bad-FCHECK edge-case streams
├── diff_engine.py     # integrated engine vs 9 real zlib builds (1080 checks)
├── bench_new.py       # convergence benchmark over fixtures/
└── bench_old.py       # naive-order comparison benchmark
```

## License

MIT
