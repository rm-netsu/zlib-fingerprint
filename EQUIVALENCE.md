# Historical zlib output-equivalence census

## Reproducible experiment (2026-10-27)

All **30 official stable releases available in this comparison** from 1.0.1
through 1.3.2 were built from their own sources and linked statically into
the version-specific C wrapper. No system-zlib substitution was used.

`scripts/equivalence_matrix.py --depth quick` ran 10,200 identical cases per
version (306,000 invocations): 68 data/size fixtures, five compression levels,
three memory levels, five strategies and two window sizes, single input and
`Z_FINISH`, with enough output space for one call. Cases cover empty data,
repeated strings, periodic strings, seeded random bytes, sparse data and sizes
around 16 KiB, 32 KiB and 64 KiB (up to 262,144 bytes). Results are stored in
`equivalence-results.json` with per-version SHA-256 signatures and first
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

The boundary experiment `scripts/probe_boundaries.py` additionally varies
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

Tool: `scripts/diff_native_legacy.py` (fixtures: empty/repeat/periodic/
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
`scripts/diff_native_class_d.py` matched 2,592 common-success streams in
3,168 safe probes against the original 1.2.2 wrapper. This validates the
covered one-shot inputs and does **not** prove equivalence for streaming APIs.
Classes A–C are native since the 2026-11-25 port (see above); the
production build no longer compiles any algorithmic zlib C source.

### Independent native-port re-audit (2026-10-27)

`scripts/audit_native_port.py` compares native Zig output to official
per-release zlib wrappers using 33 deterministic fixtures (empty, repeated,
periodic, random, block-boundary and match-boundary inputs up to 262144 bytes),
varied compression levels, `memLevel`, strategies, and window sizes.
The reproducible output is `native-port-audit.json`.

| Scope | Differential attempts | Differences |
|---|---:|---:|
| Class D, zlib 1.2.2 | 1,254 | 0 |
| Every release zlib 1.2.3–1.3.2 (14 versions) | 21,252 | 0 |
| Total native-Zig audit | **22,506** | **0** |

The existing `scripts/diff_engine.py` suite also passed 1,080/1,080
comparisons, and `scripts/diff_legacy_native.py` passed 9,088 additional
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
python3 scripts/equivalence_matrix.py --depth quick --out equivalence-results.json
python3 scripts/probe_boundaries.py
zig build -Doptimize=ReleaseFast
python3 scripts/diff_legacy_native.py
python3 scripts/diff_native_legacy.py   # native A-C vs C cores + member binaries
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
(`version-matrix.json`, tool: `scripts/version_matrix.py`).

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
(`src/zopfli/release.zig` variant parameter). Native vs official CLI:
356/356 byte-exact combinations in `scripts/diff_zopfli_native.py`, plus
89/89 combinations inside the matrix, with round-trip decompression for
every produced stream.

**Search integration:** on a `78 da` stream only the G3 representative
(1.0.3) is searched; on a `78 01` stream only G2 (1.0.1) and G1 (1.0.0),
in that order. The order is justified by measurements
(`scripts/zopfli_ordering_bench.py`, `zopfli-ordering-bench.json`): the
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
python3 scripts/diff_zopfli_native.py        # needs built-<ver>/zopfli-<ver> reference CLIs
python3 scripts/version_matrix.py --quick    # reduced corpus; full run: drop --quick (or use --from/--to chunks)
python3 scripts/fingerprint_release_check.py # end-to-end search per release
python3 scripts/zopfli_ordering_bench.py     # order justification measurements
```

Reference CLIs are built from the tagged sources, e.g.:
`tar -xzf zopfli-1.0.2.tar.gz && cd zopfli-zopfli-1.0.2 && make zopfli`.
Tarball SHA-256 values are recorded in `version-matrix.json`.
