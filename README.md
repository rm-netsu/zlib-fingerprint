# zlib-fingerprint

**Historical release equivalence audit:** see [EQUIVALENCE.md](EQUIVALENCE.md)
for the 30-version, 306,000-invocation differential experiment, including
new pre-1.2.3 classes, the 1.3.2 check, and the output-buffer-dependent
1.2.9/1.2.10 distinction.

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
   run here, filtered by their header mappings. `--extended-zopfli` adds
   uncommon Zopfli iteration counts only after the standard candidates.
3. **windowBits distrust sweep** — only when the header is non-canonical
   (invalid FCHECK, CINFO=0) or when `--paranoid` is passed. With a
   canonical header a differing windowBits emits different header bytes,
   so the sweep is provably useless and is skipped with an explanation.

Duplicate candidates across stages are eliminated through a visited set.

## The integrated zlib engine

By default, stock zlib candidates are **not** spawned as binaries. The
modern 1.2.3–1.3.2 classes **and class D (1.2.1–1.2.2)** run through the
shared native Zig engine in `src/deflate/`; the three earlier classes
(A–C, 1.0.1–1.2.0) still use original historical C deflate sources compiled
and linked directly into the program (`src/legacy/`). Class D's C source is
retained as a differential reference. No old zlib DLL or subprocess is required.
The behavior targets the tested one-shot `Z_FINISH` producer model.
The modern Zig engine aborts mismatches at the first divergent output chunk.

### Zopfli historical releases 1.0.0 – 1.0.3 (fully native Zig port)

Zopfli is available in the default fingerprint search **in-process**,
without a subprocess, a Zopfli executable, or any linked C kernel — for
**every official historical release**: 1.0.0, 1.0.1, 1.0.2 and 1.0.3.
Each release's RFC 1950 envelope and Adler checksum are native Zig
(reusing the existing shared checksum), and the complete optimizer — bit
output, rolling hash, longest-match cache, LZ77 token-store lifecycle,
greedy/lazy parsing, optimal-path reconstruction, symbol statistics with
deterministic frequency perturbation, forward dynamic-programming
optimization, iterative squeeze, block splitting, the bounded
package-merge length-limited Huffman kernel (`katajainen.zig`), block cost
evaluation and full DEFLATE serialization — runs in native Zig. Options
replicate upstream `util.c`'s `ZopfliInitOptions`; libc is linked only for
`malloc`/`free`/`log`, and no algorithmic upstream C source is compiled
into the build. The upstream 1.0.3 distribution remains in
`binaries/vendor/zopfli-zopfli-1.0.3/` as the independent reference and
audit baseline.

The release behaviour differences are reproduced explicitly through the
`ZopfliRelease` variant (`src/zopfli/release.zig`), never through a mutable
global switch:

| Aspect | 1.0.0 | 1.0.1 | 1.0.2 / 1.0.3 |
|---|---|---|---|
| RFC 1950 header | `78 01` (FLEVEL=0) | `78 01` | `78 da` (FLEVEL=3) |
| Dynamic tree encoding | fixed RLE strategy | 8-strategy search | 8-strategy search |
| Histogram RLE optimization | none | always | try both, keep smaller |
| Block type selection | dynamic/fixed only | dynamic/fixed only | auto (stored/fixed/dynamic) |
| Block splitting cost | dynamic-only | dynamic-only | auto-type |
| Master block size | 20,000,000 | 20,000,000 | 1,000,000 |
| Empty input | CLI refuses (no stream) | CLI refuses | fixed empty block |

1.0.2 and 1.0.3 share one code path: their only source difference is a
`malloc` cast in `deflate.c` with no observable effect for any admissible
length; the byte-level matrix confirms byte-identity across the whole
corpus, and the search collapses 1.0.2 into the 1.0.3 representative while
reporting the group range `zopfli 1.0.2-1.0.3` on a match.

The regression `python3 scripts/diff_zopfli_native.py` compares the native
variants against the independent release CLIs (356/356 byte-exact in the
delivery environment; each matched stream also round-trips through zlib
decompression), and the dedicated kernel differential
`python3 scripts/diff_katajainen.py` passed 4042/4042 byte-exact vectors
against the original `katajainen.c`. The full byte-level equivalence
matrix of the four releases (`python3 scripts/version_matrix.py`) is
described in `EQUIVALENCE.md`; its report is in `version-matrix.json`.
See `src/zopfli/README.md` for module boundaries.

A deterministic iteration probe (`python3 scripts/probe_zopfli_iterations.py
--max-iteration 30 --stress`) found no extra unique Zopfli output when
testing 1–30 and 50 iterations across six fixtures: four fixtures produced
one distinct stream, two produced two streams already covered by the defaults.
Consequently extra iterations are opt-in, avoiding a large increase in search
cost for the usual case.

### Verifying the native port

After building the project and the original reference wrappers in `binaries/`:

```sh
python3 scripts/audit_native_port.py
python3 scripts/diff_native_class_d.py
python3 scripts/diff_legacy_native.py
```

The expanded native audit compared **22,506** original/native runs across
all 15 releases from 1.2.2 through 1.3.2 without a mismatch. Its per-release
results are in `native-port-audit.json`; limitations and test parameters
are described in `EQUIVALENCE.md`.

### Where the output actually changed (1.2.3 → 1.3.2)

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
{ 1.2.3 }  { 1.2.4-1.2.8 }  { 1.2.9 }  { 1.2.10-1.3.2 }
```

The search tries the minimal set of representatives per parameter
combination (`collapseGroups`): one for most combinations, two for
Z_HUFFMAN_ONLY / Z_RLE (1.2.3 vs 1.2.4+ block states) and up to four at
level 0 (three stored-block generations). A match is reported with the
honest version range the representative reproduces, e.g.
`level=6, memLevel=8, strategy=default, windowBits=15, zlib 1.2.3-1.3.2`.

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
| zlib (integrated), 1.2.3 – 1.3.2 | in-process | full `level memLevel strategy windowBits` matrix; 1.3.2 covered in tested one-shot model |
| zlib class D, 1.2.1–1.2.2 | native Zig (shared 1.2.3 engine, historical strategy limits) | verified with original 1.2.2 oracle; all releases available with `--external-zlib` |
| zlib classes A–C, 1.0.1–1.2.0 | in-process, statically linked historical C | one built-in representative per class; native Zig port pending |
| zlib 1.2.3 / 1.2.5 / 1.2.7 / 1.2.8 / 1.2.11 / 1.2.12 / 1.2.13 / 1.3 / 1.3.1 / 1.3.2 | external binaries | skipped in default mode (integrated); enabled with `--external-zlib` |
| zlib-ng 2.2.1 (compat) | external binary | `level memLevel strategy`, windowBits fixed to 15 |
| Zopfli 1.0.3 / 1.0.2 / 1.0.1 / 1.0.0 | in-process | release-specific behaviour (header, tree encoder, block selection); 1.0.2 collapsed into the 1.0.3 representative (byte-identical), reported as `zopfli 1.0.2-1.0.3` |
| Zopfli 1.0.3 | external binary | `--zlib -c --iN <file>`; header `0x78 0xDA`; enabled with `--external-zlib` |
| libdeflate 1.20 | external binary | `level` (1–12) |
| miniz 3.1.2 | external binary | `level` (1–10) |
| AdvanceCOMP 2.6 advdef | external binary | `-L -z -k` on a temp file; last resort |

Missing binaries are detected once up front and their profiles are
skipped. Without any external binaries, the tool fingerprints all eight
historical stock zlib classes from 1.0.1–1.3.2 in the tested one-shot model.

The earlier classes are A (1.0.1–1.0.5), B (1.0.6–1.0.9), C
(1.1.0–1.2.0) and D (1.2.1–1.2.2). Their in-process priority is
**D → C → B → A**, after modern stock zlib; external alternatives follow.
`--external-zlib` instead audits individual historical binaries. For safety,
level 0 with strategy 2/3 and class A level 0 with memLevel below 8 are
excluded from the native C paths pending sanitizer checks; these unusual
combinations can still be investigated with external binaries.

The pre-1.2.3 releases are not classified as equivalent to modern zlib:
their DEFLATE output may differ, and their header/strategy behavior has
not been exhaustively characterized. Therefore their candidate headers are **not** rejected by
the modern zlib FLEVEL prediction. In normal mode they use statically
linked original sources. Exact per-release audit still uses optional
binaries from `binaries/build-binaries.sh`. The pre-1.0 experimental series is
not included, nor are unreleased source snapshots.

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
# Cross-compilation (verified by build; run-verification requires the OS):
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos
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

Mode: eight integrated stock zlib classes + external alternatives (availability varies)

==> Stage 1: metadata-guided pass (6 candidates)

[SUCCESS] Bit-exact match found!
- Implementation: zlib (integrated)
- Stage         : Stage 1: metadata-guided pass
- Parameters    : level=6, memLevel=8, strategy=default, windowBits=15
- Versions      : zlib 1.2.3-1.3.2 (integrated engine)
- Convergence   : 1 attempt, 10 ms
```

With `--verbose` / `-v` every attempt is logged (the bracketed suffix
names the covered zlib version range for the current parameter
combination):

```text
  [attempt     1] P1 zlib (integrated) | lvl=6 mem=8 strat=default wBits=15 [zlib 1.2.3-1.3.2] -> MATCH
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
    ├── deflate.zig    # version registry (1.2.2–1.3.2 / 4 byte-output classes), dispatch,
    │                  # one-shot compressor with early-abort comparison
    ├── state.zig      # shared deflate_state, bit output, window, hash,
    │                  # longest_match, longest_match_fast (1.2.3-only paths)
    ├── tables.zig     # configuration_table, static trees, length/distance codes
    ├── trees.zig      # shared trees.c: block flush, tree building, codes
    ├── stored_legacy.zig  # deflate_stored, zlib 1.2.3-1.2.8  ┐ version-specific
    ├── stored_1_2_9.zig   # deflate_stored, zlib 1.2.9         ├─ generations
    ├── stored.zig         # deflate_stored, zlib 1.2.10-1.3.2  ┘
    ├── fast.zig / slow.zig          # deflate_fast/slow, zlib 1.2.4+
    ├── fast_1_2_3.zig / slow_1_2_3.zig  # 1.2.1–1.2.3 variants (shared paths)
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
