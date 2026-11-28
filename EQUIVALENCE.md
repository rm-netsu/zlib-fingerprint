# Historical zlib output-equivalence census

## Reproducible experiment (2026-10-27)

All **30 official stable releases available in this comparison** from 1.0.1
through 1.3.2 were built from their own sources and linked statically into
the version-specific C wrapper. No system-zlib substitution was used.

`zlib-replicant/scripts/equivalence_matrix.py --depth quick` ran 10,200 identical cases per
version (306,000 invocations): 68 data/size fixtures, five compression levels,
three memory levels, five strategies and two window sizes, single input and
`Z_FINISH`, with enough output space for one call. Cases cover empty data,
repeated strings, periodic strings, seeded random bytes, sparse data and sizes
around 16 KiB, 32 KiB and 64 KiB (up to 262,144 bytes). Results are stored in
`zlib-replicant/results/equivalence-results.json` with per-version SHA-256 signatures and first
distinguishing cases for every non-equivalent pair.

Eight empirical classes when **return status is part of the signature**:

| Class | Releases | Representative |
|---|---|---|
| A | 1.0.1, 1.0.2, 1.0.4, 1.0.5 | 1.0.5 |
| B | 1.0.6, 1.0.7, 1.0.8, 1.0.9 | 1.0.9 |
| C | 1.1.0, 1.1.1, 1.1.2, 1.1.3, 1.1.4, 1.2.0 | 1.2.0 |
| D | 1.2.1, 1.2.2 | 1.2.2 |
| E | 1.2.3 | 1.2.3 |
| F | 1.2.4, 1.2.5, 1.2.6, 1.2.7, 1.2.8 | 1.2.8 |
| G | 1.2.9 | 1.2.9 |
| H | 1.2.10, 1.2.11, 1.2.12, 1.2.13, 1.3, 1.3.1, 1.3.2 | 1.3.2 |

The boundary experiment `zlib-replicant/scripts/probe_boundaries.py` additionally varies
`avail_out` (64, 1024, 32768 bytes or unrestricted), yielding concrete
successful-output differences:

| Boundary | First successful-output witness | Notes |
|---|---|---|
| A / B | 65,535 repeated `A` bytes, level=0, mem=8, strategy=0, window=15, output chunk=64 | Older releases also differ in accepted options |
| B / C | 131,072 periodic bytes, level=3, mem=8, strategy=0, window=9, unrestricted | Both successful |
| C / D | empty, level=0, mem=1, strategy=0, window=9, output chunk=64 | Both successful |
| D / E | **No successful-output difference found** in 8,160 common successful quick-matrix cases; 1.2.3 accepts Z_FIXED where 1.2.2 rejects it | Capability class rather than proven byte-stream class |
| E / F | 32 repeated `A` bytes, level=1, mem=1, strategy=3, window=9, output chunk=64 | Both successful |
| F / G | empty, level=0, mem=1, strategy=0, window=9, output chunk=64 | Both successful |
| G / H | empty, level=0, mem=1, strategy=0, window=9, output chunk=64 | 1.2.9 emits 6 bytes, 1.2.10 emits 11 bytes; **unrestricted one-call buffer did not distinguish them** |

Most importantly, the previously claimed separation of 1.2.9 and 1.2.10
is **conditional on the output-buffer call pattern**: it was not observed
in the large-one-shot-buffer matrix but is real with smaller `avail_out`.
Conversely, the 1.2.3 boundary is so far supported by API capabilities,
not a witness of differing bytes where both versions succeed.

The previous class for 1.2.10–1.3.1 extends **empirically** to 1.3.2:
no difference across all 10,200 quick-matrix probes, and none in the
1,344 shared-success calls of the buffer-size boundary experiment.

## Native classes A-C port (2026-11-25)

The three pre-1.2.1 classes were ported from their vendor C sources into
the shared native Zig engine and verified before the fingerprint
executable dropped its last algorithmic C code:

| Comparison | Cases | Differences |
|---|---:|---:|
| native A/B/C vs statically linked original C cores (`zlegacy`) | 43,619 total | **0** |
| native representative vs every official class-member binary (1.0.1 … 1.2.0, 16 releases) | included above | **0** |
| decompression round-trip of every produced stream | included above | **0** |

Tool: `zlib-replicant/scripts/diff_native_legacy.py` (fixtures: empty/repeat/periodic/
random/sparse/heuristic-trigger/text inputs up to 262,144 bytes including
all stored-block and window boundaries; levels 0-9, memLevel 1/8(/9),
strategies 0-2, windowBits 9/15 plus the windowBits-8 level-0 paths;
624 oracle-unsafe probes skipped and counted).

### What actually differs per class (source-verified, oracle-confirmed)

* **Header FLEVEL (all of A-C):** `level_flags = (s->level-1) >> 1`
  clamped to 3, computed in unsigned arithmetic — level 0 wraps to
  FLEVEL=3 — and the strategy is not consulted. Empirically confirmed
  against the 1.0.5/1.0.9/1.2.0 binaries for every level and strategy:
  levels 1-2 -> 0, 3-4 -> 1, 5-6 -> 2, 7-9 -> 3, level 0 -> 3.
* **Class A (1.0.1-1.0.5):** `deflate_stored` clamps `strstart` at 0xffff
  without flushing and emits blocks at `strstart - block_start >=
  MAX_DIST` only; there is no pending-size cap, so at windowBits 15 the
  first fill already fills the whole 64 KiB window and the first stored
  block is 65,535 bytes (vs 65,531 from 1.0.6 on). At memLevel 8 the real
  1.0.5 thereby overruns its 65,536-byte pending buffer by 4 bytes and
  survives only thanks to allocator slack; at lower memLevels it aborts —
  those probes stay excluded from the search.
* **Class B (1.0.6-1.0.9):** the early-block-stop heuristic in `_tr_tally`
  (`level > 2 && (last_lit & 0xfff) == 0 && matches < last_lit/2 &&
  out_length < in_length/2 -> flush`) is still unconditional; 1.1.0 moved
  it behind `#ifdef TRUNCATE_BLOCK` (off by default), which is the first
  byte-level B/C boundary (witness: periodic-131072, level 3, mem 8,
  strategy 0, window 9 -> 2020 vs 2001 bytes).
* **Class C (1.1.0-1.2.0):** B minus the heuristic; windowBits 8 is
  rejected (`windowBits < 9`); strategies are limited to 0-2.
* **fill_window (A-C):** the pre-1.2.x shape — full-window slide copy, no
  WIN_INIT zero-fill, hash re-initialized from `strstart` on every fill —
  ported faithfully as `state.fillWindowLegacy`.
* **windowBits 8 (A/B):** w_size 256 < MIN_LOOKAHEAD 262 makes the
  standalone `MAX_DIST` macro wrap to ~4 billion while the fill_window
  slide threshold `wsize+MAX_DIST(s)` wraps to 250. At level 0 the result
  is a deterministic (data-losing, corrupt) stream — no stored block is
  flushed, `block_start` slides negative and the final flush emits an
  empty static-Huffman block — which the port reproduces byte-exactly.
  At level >= 1 the match finder follows stale chain entries with wrapped
  distances into out-of-bounds reads (`dist_code` indexing); those probes
  are excluded from the search.

### Search integration consequences

* Header prediction now covers classes A-C (`hints.zlibLegacyContainerHeader`),
  pruning candidates whose level cannot reproduce the observed FLEVEL.
* Legacy strategy-2 candidates exist at *every* hinted level (the legacy
  FLEVEL ignores the strategy); the pre-port search never generated them,
  so legacy huffman-only streams at levels 2-8 were previously unfindexable.
* Streams reproducible by several classes (uniform data at level 2 makes
  A, B and C coincide; levels 7-9 make class C coincide with modern zlib)
  are attributed to the highest-priority reproducer, matching the modern
  classes' collapse semantics.

### Interpretation and limits

- These are *observed equivalence classes*, **not mathematical proof** that
  every possible input/parameter/flush sequence yields identical bytes.
- Comparing return codes is useful for fingerprinting capabilities, but
  outputs must be compared only when both compressors returned success.
- A class may split under more elaborate streaming patterns (`Z_SYNC_FLUSH`,
  multiple input chunks, dictionaries, `deflateParams`), different build
  macros, architectures or an output cap beyond the tested values.
- The integrated Zig compressor covers 1.2.3–1.3.2 in the tested one-shot
  model. zlib 1.3.2 is supported based on empirical differential testing;
  untested streaming behavior remains in `BACKLOG.md`. All four legacy
  classes A–D now run native Zig engines verified against their original C
  sources and the official release binaries; the C cores remain linked
  into the `zlegacy` dev tool as independent oracles. The full per-release
  audit still uses external binaries.
- This census begins with stable zlib 1.0.1. The earlier experimental
  0.x releases and nonstandard vendor forks are outside its scope.

## Native class-D migration (incremental)

Class D (1.2.1–1.2.2) uses the same Zig `fast_1_2_3`, `slow_1_2_3`,
`stored_legacy`, `state` and `trees` modules as 1.2.3, with `Z_FIXED`
rejected at the parameter-validation boundary. Its separate C source
remains available as an independent oracle in `zlegacy`.
`zlib-replicant/scripts/diff_native_class_d.py` matched 2,592 common-success streams in
3,168 safe probes against the original 1.2.2 wrapper. This validates the
covered one-shot inputs and does **not** prove equivalence for streaming APIs.
Classes A–C are native since the 2026-11-25 port (see above); the
production build no longer compiles any algorithmic zlib C source.

### Independent native-port re-audit (2026-10-27)

`zlib-replicant/scripts/audit_native_port.py` compares native Zig output to official
per-release zlib wrappers using 33 deterministic fixtures (empty, repeated,
periodic, random, block-boundary and match-boundary inputs up to 262144 bytes),
varied compression levels, `memLevel`, strategies, and window sizes.
The reproducible output is `zlib-replicant/results/native-port-audit.json`.

| Scope | Differential attempts | Differences |
|---|---:|---:|
| Class D, zlib 1.2.2 | 1,254 | 0 |
| Every release zlib 1.2.3–1.3.2 (14 versions) | 21,252 | 0 |
| Total native-Zig audit | **22,506** | **0** |

The existing `zlib-replicant/scripts/diff_engine.py` suite also passed 1,080/1,080
comparisons, and `zlib-replicant/scripts/diff_legacy_native.py` passed 9,088 additional
safe comparisons of statically linked A–D C adapters against independent
original wrappers, skipping 1,152 potentially unsafe historical C cases.
The targeted class-D test passed 3,168 probes, including 2,592 common-success
streams. Unit tests, ReleaseSafe and Windows x86_64 cross-compilation passed.

**Verification boundary:** all these tests exercise the supported one-shot
`Z_FINISH` producer model. They do not establish identical output for all
possible `avail_in`/`avail_out` chunking, dictionary use, mid-stream parameter
changes or non-final flush operations. Those remain explicitly deferred in
`BACKLOG.md`; the empirical equivalence classes should not be interpreted
as mathematical proof of full API identity.

### Repeat

```sh
ZLIB_ONLY=1 bash binaries/build-binaries.sh
python3 zlib-replicant/scripts/equivalence_matrix.py --depth quick --out zlib-replicant/results/equivalence-results.json
python3 zlib-replicant/scripts/probe_boundaries.py
zig build -Doptimize=ReleaseFast
python3 zlib-replicant/scripts/diff_legacy_native.py
python3 zlib-replicant/scripts/diff_native_legacy.py   # native A-C vs C cores + member binaries
```

`--depth full` also sweeps every level 0–9 and additional `memLevel=4`;
it has a substantially higher running cost and was **not** executed for
this report. The one-shot fixture and matrix generator are deterministic.

## Zopfli official-release equivalence matrix (2026-10-29)

The four official Zopfli releases were built independently from the tagged
sources and compared byte-for-byte with each other and with the native Zig
release variants on a 38-input corpus (356 full-stream combinations):
empty/short inputs, repeats, periodic sequences, dictionary-reuse, text,
JSON-like data, fixed-seed random data, mixed compressible/incompressible
regions, ~32 KiB window boundaries, 999999/1000000/1000001 master-block
boundaries, 20,000,001-byte legacy master-boundary inputs, and inputs aimed
at the discovered tree-encoder differences. Every stream was round-tripped
through zlib decompression; every run recorded version, parameters, input
id, process status, output size, SHA-256 and decompression success
(`zopfli-replicant/results/version-matrix.json`, tool:
`zopfli-replicant/scripts/version_matrix.py`).

**Observed result classes (full streams):**

| Group | Members | Evidence |
|---|---|---|
| G1 | zopfli 1.0.0 | differs from every other release on all 89 reference combinations (header `78 01`, no RLE histogram optimization, fixed-strategy tree encoder, no stored-block candidate) |
| G2 | zopfli 1.0.1 | differs from every other release on all 89 combinations (header `78 01`, always-RLE histogram, 8-strategy tree encoder) |
| G3 | zopfli 1.0.2, 1.0.3 | byte-identical on 89/89 combinations |

Minimal reproducible differences (first occurrence in matrix order):
- G1 vs G2: `periodic-4096` at 1 iteration (tree-encoding divergence).
- G1/G2 vs G3: `empty` input at 1 iteration (the 1.0.0/1.0.1 CLI refuses
  empty input entirely; every other combination also differs, 51/89 for
  G1-vs-G2, 89/89 for G1/G2-vs-G3).

**Source analysis backing the groups** (upstream git, tag-to-tag diffs):
- 1.0.2 -> 1.0.3 changes only `deflate.c`: `(unsigned)` cast in a malloc
  size, no behavioural effect (lengths <= 288). G3 is one output class.
- 1.0.1 -> 1.0.2 changed the container FLEVEL (0 -> 3, commit `05e3efc`),
  the master block size (20,000,000 -> 1,000,000, commit `fdb3745`),
  introduced `ZopfliCalculateBlockSizeAutoType` and the try-both
  `OptimizeHuffmanForRle` decision (commit `e0e937e`), auto block-type
  selection, the second LZ77-space splitting round, and the empty-input
  CLI fix — hence a separate class.
- 1.0.0 -> 1.0.1 rewrote the dynamic tree encoder to the 8-strategy
  search (commits `150827f`/`79e6e0c`, `b87006b`) and added
  `OptimizeHuffmanForRle` to dynamic length selection — hence a separate
  class; the blocksplitter/cache/katajainen changes in that range were
  verified behaviour-neutral (AddSorted rewrite is semantically identical,
  cache.c only gained OOM checks, katajainen's stable-sort refactor
  preserves glibc's observed ordering).

**Native variants:** all four releases run natively on Zig
(`zopfli-replicant/src/release.zig` variant parameter). Native vs official CLI:
356/356 byte-exact combinations in
`zopfli-replicant/scripts/diff_zopfli_native.py`, plus
89/89 combinations inside the matrix, with round-trip decompression for
every produced stream.

**Search integration:** on a `78 da` stream only the G3 representative
(1.0.3) is searched; on a `78 01` stream only G2 (1.0.1) and G1 (1.0.0),
in that order. The order is justified by measurements
(`zopfli-replicant/scripts/zopfli_ordering_bench.py`,
`zopfli-replicant/results/zopfli-ordering-bench.json`): the
release variants cost the same per iteration, so the choice is purely
prior-based (newest first within a header class), and the baseline
iteration set covers all distinct outputs observed on the probe fixtures
for every release. Stored-block streams are byte-identical across
implementations (zlib and all Zopfli releases); when such a stream matches
a non-Zopfli producer first, the search reports the match with an explicit
ambiguity note.

**Limits:** the matrix establishes observed equivalence over the listed
corpus and iteration set {1, 2, 3, 5, 10, 15, 50} (plus 1..30 for the
iteration probe). It is not a proof of identity for all inputs; unions are
backed by the source analysis above. Iterations outside the tested set may
still produce different streams (the optimizer's random perturbation makes
the mapping input-dependent).

### Repeat

```sh
zig build --release=fast
bash zopfli-replicant/binaries/build-references.sh   # official CLIs 1.0.0-1.0.3
python3 zopfli-replicant/scripts/diff_zopfli_native.py        # every release vs the official CLIs
python3 zopfli-replicant/scripts/version_matrix.py --quick    # reduced corpus; full run: drop --quick (or use --from/--to chunks + merge_matrix.py)
python3 scripts/fingerprint_release_check.py                  # end-to-end search per release
python3 zopfli-replicant/scripts/zopfli_ordering_bench.py     # order justification measurements
```

Reference CLIs are built by the package from the tagged official
sources (verified against `zopfli-replicant/binaries/SHA256SUMS`);
the vendored untouched 1.0.3 distribution stays at
`zopfli-replicant/binaries/vendor/zopfli-zopfli-1.0.3/`.

## Streaming-API differential census and full-depth extension (2026-11-26)

The deferred BACKLOG items were executed with a new scenario-driven
streaming wrapper (the zlib-replicant engine package's
`binaries/zstream_wrapper.c`, built per release as
`binaries/zstream-<ver>`): chunked `avail_in`, capped `avail_out`,
`Z_PARTIAL_FLUSH`/`Z_SYNC_FLUSH`/`Z_FULL_FLUSH`/`Z_BLOCK` at byte offsets
and after every chunk, mid-stream `deflateParams`, `deflateSetDictionary`
(FDICT), `deflateReset`, `deflateCopy` (source and clone continuation),
plus a single-`Z_FINISH` mode byte-identical to the historical one-shot
wrapper (cross-checked: 31 releases x 16 scenarios, 0 mismatches).

Tools: `zlib-replicant/scripts/stream_matrix.py stream` (710 scenarios, 22,010 runs,
31 releases 1.0.1-1.4) and `zlib-replicant/scripts/stream_matrix.py oneshot`
(full-depth one-shot matrix: 8,403 cases, 260,493 runs, levels 0-9,
memLevel 1/4/8/9, strategies 0-4, windowBits 9/15 over 21 boundary
fixtures incl. MIN_MATCH/MAX_MATCH repeats and exact lit_bufsize
boundaries, plus a 2 MiB mixed input at levels 1/6/9). Results:
`zlib-replicant/results/stream-matrix.json`, `zlib-replicant/results/oneshot-ext-results.json`.

### Refined equivalence structure

The one-shot byte classes A-H stand; the *streaming* surface splits four
of them further (all witnesses recorded in `zlib-replicant/results/stream-matrix.json`):

| Pair | Kind | Evidence |
|---|---|---|
| 1.0.1-1.0.2 vs 1.0.4-1.0.5 | status only | level 0 with avail_out 1-2: the 1.0.1/1.0.2 `deflate_stored` returns `Z_BUF_ERROR` where 1.0.4+ completes (18 scenarios); 1.0.1/1.0.2 also *accept* numeric flush=5 while 1.0.4-1.2.3 reject it |
| 1.1.0 vs 1.1.1-1.2.0 | bytes (rare) | mixed >= 512 KiB at level >= 4: 1.1.0 emits an extra early block flush |
| 1.2.4-1.2.5 vs 1.2.6-1.2.8 | bytes | `Z_PARTIAL_FLUSH` marks at level 1 (425 vs 424 bytes witness); 55 differing scenarios |
| 1.2.10 vs 1.2.11 vs 1.2.12-1.4 | bytes | level 0 with capped avail_out (outchunk 5: 1.2.10 alone differs; outchunk 8: all three differ); the 1.2.11 changelog confirms "Fix deflate stored bug when pulling last block from window" |

The 1.1.0 split has a source-verified cause: 1.1.0 introduced the inline
`_tr_tally_lit`/`_tr_tally_dist` macros (heuristic-free) for most call
sites but kept ONE direct `_tr_tally` function call in `deflate_slow`'s
previous-match path, so the 0xfff early-block-stop heuristic survives
there in non-DEBUG builds. 1.1.1 moved the function's heuristic behind
`#ifdef TRUNCATE_BLOCK` (off) and switched the last call site to the
macro. 1.1.0's `-DDEBUG` build does not even compile (its `deflate.h`
passes four arguments to the three-argument `_tr_tally`), so no
DEBUG/release ambiguity exists for 1.1.0. The integrated engine's class
C models 1.1.1-1.2.0; 1.1.0 diverges only on >= 512 KiB inputs at level
>= 4 where the profitability condition first aligns with a 4096-symbol
boundary (verified: 64/128/256 KiB mixed identical, 512 KiB differs).

### API capability boundaries under streaming

* `Z_BLOCK` (numeric flush 5): accepted by 1.0.1-1.0.2 (produces a valid
  stream), rejected (`Z_STREAM_ERROR`) by 1.0.4 through 1.2.3, supported
  from 1.2.4 on. At level 0 even 1.2.3 rejects it (1.2.3 vs 1.2.4 status
  witness).
* `deflateCopy`: 1.0.1-1.0.5 is an unimplemented stub returning
  `Z_STREAM_ERROR` ("to be implemented"); working from 1.0.6 on. Where it
  works, both the source stream and the clone continuation are
  byte-identical to an uninterrupted run (self-check: 0 mismatches).
* `deflateParams` to level 0 mid-stream at memLevel 1 aborts 1.0.4-1.0.5
  with heap corruption (see the ASan section); class B survives.
* `deflateReset`/`deflateParams` otherwise output-neutral: the post-reset
  stream equals a fresh one-shot stream for every tested release up to
  1.4 (0 self-check mismatches).
* Dictionaries: identical dictionaries produce identical payloads across
  all 31 releases for dict lengths 3/32/512/32768/70000 (FDICT headers
  equal); the only witness in the dict group separates 1.0.9 from 1.1.0
  on the 70000-byte dictionary (>32 KiB window) input.

### 1.2.9 / 1.2.10 level-0 truncated-stream bugs

With chunked `Z_NO_FLUSH` input at level 0, 1.2.9 emits incomplete
streams (rc=0, no final block; decompression fails) across 85 scenario
combinations, and 1.2.0-style 1.2.10 across 37 more (inchunk 64-65535
combined with avail_out 16-32768). 1.2.11 fixed the stored-block
pulling. The one-shot single-`Z_FINISH` model never triggers these: the
documented empty-input case (`7801 00000001`, 6 bytes, no final block)
cannot be inflated at all, and the fingerprint search reports it as an
honest failure (regression case `g-empty-truncated`).

### Definitive boundary conclusions

* **1.2.2 vs 1.2.3 (D/E)**: 6,723 shared-success full-depth one-shot
  cases + 678 streaming shared successes, **zero output differences**;
  1,680 + 8 status differences, all `Z_FIXED` rejections. The boundary
  is capability-only within everything tested.
* **1.3.1 vs 1.3.2 and 1.3.2 vs 1.4**: 8,403 + 710 shared successes,
  zero differences of either kind.
* **zlib 1.4 (4 Nov 2026)**: source changes (`deflateResetKeep` now
  retains window/hash and unfinished-block state, `deflateCopy`
  rewritten to allocate via the source stream, stored-path return-code
  macro, `deflatePrime` pending-buffer fixes, `deflateSetDictionary`
  validation) are all outside the one-shot RFC-1950 byte model; the
  integrated engine's class H range is extended to 1.2.10-1.4.

## Pre-1.0 research: zlib 0.71 - 0.99 (2026-11-26)

All 0.x tarballs are available from the upstream fossils archive and the
GitHub mirror (tags v0.71 ... v0.99, v1.0-pre). Source inspection of
0.71/0.79/0.8/0.9/0.91/0.93/0.95/0.99 shows the RFC 1950 header formula
(`CMF = 8 + (w_bits-8)<<4`, `FLEVEL = (level-1)>>1` clamped to 3,
FCHECK mod 31) identical across the whole series - the container format
never changed after 0.71; it matches the pre-1.2.1 legacy formula the
engine already implements.

Differentially (1,600 one-shot parameter combinations + windowBits 8):

* **zlib 0.99** (Jan 1996, `ZLIB_VERSION "1.0"`) is byte-identical to
  class A on every tested combination including windowBits 8. Class A's
  honest coverage is extended to **0.99-1.0.5**.
* **zlib 0.95** emits the same bytes wherever it succeeds but is a
  capability subset: no level 0 at all (deflateInit2 rejects it, hence
  no stored streams), accepts numeric strategy 3 that 1.0.1+ reject,
  and its public header has no `deflateParams`, `deflateSetDictionary`
  or `deflateReset`; `deflateCopy` is the same unimplemented stub as
  1.0.1-1.0.5. Its flush constants are swapped relative to every later
  release (`Z_FULL_FLUSH 2`, `Z_SYNC_FLUSH 3`), so binary flush values
  are not comparable across the 1.0 boundary.

0.71-0.93 were not differentially run (their API predates even
`deflateInit2` argument validation differences); the header formula and
validation shape (level 1-9, windowBits 8-15) are source-identical to
0.95.

## ASan/UBSan validation of the documented unstable paths (2026-11-26)

`zlib-replicant/scripts/asan_unstable.py` rebuilds 1.0.5, 1.0.9, 1.2.0, 1.2.2, 1.2.4,
1.2.8, 1.2.9, 1.2.11 with
`-fsanitize=address,undefined -fno-sanitize-recover=all` and runs the
excluded paths plus controls. Results in `zlib-replicant/results/asan-results.json`:

* class A level 0 with memLevel 1/4/7: **heap-buffer-overflow** in
  `deflate_stored` (pending-buffer overrun) - the search's exclusion is
  validated.
* windowBits 8 at level >= 1 on 1.0.5/1.0.9: **SEGV** (the wrapped
  `MAX_DIST` out-of-bounds path crashes outright under ASan).
* `deflateParams` 9 -> 0 at memLevel 1 on 1.0.5: **heap-buffer-overflow**
  (the streaming matrix's SIGABRT reproduced as memory corruption);
  1.0.9 with identical parameters is clean.
* 1.2.11 level 0 control: UBSan flags `memcpy(dst, NULL, 0)` in the
  empty-stored-block emission (`_tr_stored_block(s, (char *)0, 0, ...)`)
  - a benign by-the-letter UB fixed in later zlib, not a memory-safety
  violation; with `-fno-sanitize-recover` the case aborts before
  producing output.
* The README's 1.2.4-1.2.8 "level 0 + strategy 2/3 heap overflow" claim
  could **not** be reproduced by this harness under the swept conditions
  (one-shot and avail_out 1-4096, text/random payloads 0-131072 bytes,
  memLevel 1/4/8, windowBits 8/15, both strategies): all runs completed
  cleanly. The path remains excluded from the search and the original
  verification stands, but the triggering conditions are narrower than
  the README wording suggested (corrected there).

## Build-option output equivalence (2026-11-26)

`zlib-replicant/scripts/build_options_check.py` compiles 1.1.4, 1.2.3 and 1.2.11 with
`-O0`, `-O3`, `-DUNALIGNED_OK` and `-DDEBUG` and compares 180
fixture/parameter combinations against the default build:
**byte-identical everywhere** (`zlib-replicant/results/build-options-results.json`).
`-DFASTEST` (available since 1.1.0) legitimately changes the output
(forces level 1, no hash chains): 12 of 60 FASTEST comparisons differ,
the rest coincide with the default build on these fixtures. x86-64
only; ARM64 runs were not executed in this environment.

## Zopfli matrix extension: new iterations and a 24 MiB corpus (2026-11-26)

`zopfli-replicant/scripts/zopfli_matrix_ext.py` extends the release
matrix with iteration
counts {4, 6, 7, 8, 9, 12, 20, 30, 60, 100} (outside the baseline
{1, 2, 3, 5, 10, 15, 50}) on six corpus inputs, and with a 24 MiB mixed
corpus at iterations 1 and 2 for all four releases. Every case compares
the official release CLI (rebuilt from the tagged sources) with the
native Zig variant: **68/68 byte-identical, 0 round-trip failures**
(`zopfli-replicant/results/zopfli-matrix-ext.json`). The producer grouping
reproduces the known G1/G2/G3 classes; no release pair merged or split under the new
iteration values, and the native port stays byte-exact at 100 iterations
and on 24 MiB inputs.

## Regression fixtures and CI (2026-11-26)

`zlib-replicant/fixtures-regression/` + `zlib-replicant/scripts/regression_check.py` pin 16+4 minimal
witnesses (every class boundary, the wbits-8 data-losing stream, the
1.2.9 truncated empty stream, Zopfli 1.0.0/1.0.1/1.0.3 identification,
zlib 1.4, miniz/zlib-ng representatives) as golden streams with SHA-256
manifests. The whole corpus moved into the zlib-replicant package
together with the engine's differential stack; the checker resolves the
tools of both the package and the enclosing repository (refenv.py) and
skips companion-engine cases when their tools are absent. The engine's
own CI moved into the package as well — `zlib-replicant/.github/
workflows/ci.yml` runs the engine unit tests, the golden-corpus
regression incl. official wrappers, and both differential matrices on
every push; the repository-level `.github/workflows/ci.yml` keeps the
search, package-integration and sibling-engine checks. The dependency
form of the package is lightweight by design: `.paths` in
`zlib-replicant/build.zig.zon` ships only `src/` + build files + README,
so a fetched copy carries the engine alone while the oracles, suites,
golden corpus and CI stay in the development repository (documented in
`zlib-replicant/DEV.md`; the engine consumed from the dependency form was
verified byte-identical to the development harness across 2,336
class-A-H comparisons).

The regression harness immediately paid off: it caught the search never
trying `Z_RLE` at levels other than 9 (a wrong "level does not matter"
assumption - 1.2.3-and-earlier `Z_RLE` runs through
`deflate_fast`/`deflate_slow` and is level-dependent; fixed in
`src/fingerprint.zig`, stage 1 now probes level 1 and stage 2 sweeps
levels 1-8 for strategy 3).


## Native zlib-ng 2.2.1 (compat) and miniz 3.1.2 ports (2026-11-27)

Two more external zlib-family implementations became native in-process
engines of the fingerprint search. Both ports target the one-shot producer
model of their reference wrappers and were verified byte-exactly against
the official sources.

### zlib-ng 2.2.1 (compat)

* Scope: every strategy function of the default release build (QUICK and
  MEDIUM strategies enabled) — `deflate_stored`, `deflate_quick`,
  `deflate_fast`, `deflate_medium` (the zlib-ng-specific lazy algorithm
  with `insert_match`/`fizzle_matches`), `deflate_slow`,
  `deflate_rle`, `deflate_huff` — plus the shared machinery (integer and
  rolling hash inserts, `fill_window`/high-water WIN_INIT, 64-bit `bi_buf`
  output, trees.c including the `ct_data` union semantics, LIT_MEM symbol
  buffers, `deflate_stored`'s direct-copy layout, the zlib header and MSB
  Adler-32 trailer).
* `windowBits` is fixed to 15 exactly like the reference wrapper (it
  accepts the argument but passes a literal 15 to `deflateInit2`).
* Deterministic-build assumption: the reference is the x86-64 little-endian
  build (UNALIGNED_OK + UNALIGNED64_OK `longest_match` filter semantics);
  the arch-dispatched AVX2/SSE2 kernels compute the same values as the
  ported generic kernels — confirmed by the differential matrix.
* Verification: 130 fixture runs (13 payloads x levels 0-9), the 450-case
  `(level 0-9) x (memLevel 1,4,9) x (strategy 0-4)` parameter matrix and
  60 randomized stress runs — **0 mismatches**; every compared stream
  round-trips through zlib decompression (`scripts/diff_native_zlibng.py`).
* Known details the port had to reproduce exactly (all found by the
  differential harness): the `ct_data` union mapping (freq shares the
  code slot, dad shares the len slot), the C's `int32_t bi_valid` that
  `bi_windup` can drive negative, the GOTO_NEXT_CHAIN filter order (the
  current candidate is checked before the chain advances), and
  `emit_match`/`insert_match` taking the match struct by value.

### miniz 3.1.2

* Scope: the complete tdefl compressor in the **released** build
  configuration — the release defaults
  `MINIZ_USE_UNALIGNED_LOADS_AND_STORES` to 0 on every architecture, so
  the reference wrappers compile the scalar variants only: byte-wise
  `tdefl_find_match`, the plain `tdefl_compress_lz_codes`, and level 1
  runs the greedy `tdefl_compress_normal` (`tdefl_compress_fast` is not
  compiled at all in this configuration).
* The `mz_compress2` one-shot model is preserved (mem_level validated but
  ignored by tdefl, window bits 15, default strategy, compressBound+64
  output buffer), as are the probe-table level mapping, the raw-block
  fallback when a coded block would expand the data, the level-0
  raw-block mode, and the FLEVEL computation by reversing the probe-table
  lookup.
* Verification: 340 runs (20 fixtures x levels 0-10 + 120 randomized
  stress cases) — **0 mismatches**; every compared stream round-trips
  (`scripts/diff_native_miniz.py`).

### Remaining external implementations

libdeflate 1.20 (levels 1-12 across four algorithms: fastest, greedy,
lazy/lazy2 and near-optimal parsing plus block splitting and the optimal
precode — roughly 3000 lines of intricately tie-broken C), AdvanceCOMP's
vendored 7-zip deflate (advdef -3) and the advdef recomposition passes
that depend on libdeflate-12 (-2, -4) remain external binaries: their
streams are still fingerprinted through `binaries/libdeflate-1.20` and
`binaries/advdef-2.6` when present, and honestly reported as no match
otherwise.
