# zlib-fingerprint

A command-line tool that detects the exact `zlib`/`deflate` implementation and
compression parameters needed for **bit-exact reproduction** of a compressed
stream from its uncompressed data.

This is a native Zig 0.16 port of my local TypeScript tool
`zlib-fingerprint-cli`.

---

## Features

* **Integrated historical zlib engine (default):** bit-exact in-process
  reimplementation of zlib 1.2.3 – 1.3.1 deflate. Places where the compressed
  output changed between versions live in separate version-labelled modules;
  everything that never changed is shared code (see below).
* **Multi-implementation support:** probes the integrated zlib engine plus
  external binaries (`zlib-ng`, `Zopfli`, `libdeflate`, `miniz`, `advdef`).
  `--external-zlib` falls back to spawning historical zlib wrapper binaries
  like the original tool did.
* **Three-phase brute-force fingerprinting:** trusted header metadata first,
  then the full parameter matrix, then reduced window sizes. Mismatching
  candidates abort at the first divergent output chunk, which keeps the full
  matrix fast (thousands of attempts per second even on multi-MB inputs).
* **Bit-exact comparison:** every candidate's output is compared
  byte-for-byte against the original compressed stream.
* **Zero-copy inflate:** decompression uses Zig's `std.compress.flate`
  (zlib container) instead of Node's `zlib.inflateSync`.
* **Enhanced CLI:** colored output (ANSI / Windows console API), a live
  progress indicator, a global attempt counter and a verbose per-attempt log.
  Respects `NO_COLOR` / `CLICOLOR_FORCE`.
* **Deadlock-free subprocess handling** (external profiles): stdin is fed
  from a worker thread while stdout is drained concurrently — multi-megabyte
  inputs work reliably.

---

## The integrated zlib engine

### Where the output actually changed (1.2.3 → 1.3.1)

Established by diffing every release **and** by a 28 496-combination
differential matrix over 13 compiled historical versions (10 corpus files ×
levels 0-9 × strategies 0-4 × memLevels {1,2,8,9} × windowBits {9,14,15}):

1. **`deflate_stored` / level 0 — three generations**
   (`stored_legacy.zig` → `stored_1_2_9.zig` → `stored.zig`);
   1.2.9 additionally emits no final block for empty input.
2. **`Z_RLE` (strategy 3)** — 1.2.3 uses `deflate_fast`/`deflate_slow` with
   `longest_match_fast`; 1.2.4+ has the dedicated `deflate_rle` (`rle.zig`).
3. **`Z_HUFFMAN_ONLY` (strategy 2)** — 1.2.3 disables match search inside
   `deflate_fast`/`deflate_slow`; 1.2.4+ has the dedicated `deflate_huff`
   (`huff.zig`) whose fill_window timing can shift block boundaries.
4. **`deflate_fast`/`deflate_slow` internals** — strategy checks live inside
   the functions in 1.2.3 (`fast_1_2_3.zig` / `slow_1_2_3.zig`).

Everything else — `longest_match`, `fill_window`, the whole `trees.c` Huffman
machinery, tables, adler32, stream framing — is byte-identical across the
entire range and lives in shared modules only.

### Output-equivalence classes

```text
{ 1.2.3 }  { 1.2.4-1.2.8 }  { 1.2.9 }  { 1.2.10-1.3.1 }
```

At the parameter combinations the search visits (level ≥ 1) the classes
collapse further: only strategy 2/3 separates 1.2.3 from the rest, so the
search tries one representative per combination (two for Z_HUFFMAN_ONLY /
Z_RLE) and reports the honest version range, e.g.
`level=6, memLevel=8, strategy=0, windowBits=15, zlib 1.2.3-1.3.1 (Phase 2)`.

### Known divergence from real zlib (documented UB)

Running `deflate_huff`/`deflate_rle` **at level 0** with zlib 1.2.4-1.2.8
triggers `_tr_flush_block`'s `level == 0 -> force a stored block` branch with
`stored_len` up to `(lit_bufsize-1) * 258` — far beyond zlib's own pending
buffer. Genuine zlib 1.2.4-1.2.8 heap-overflows there and emits a corrupted
stream (verified with AddressSanitizer against the unmodified C sources).
The search never visits level 0, and this port models the idealized (valid)
stream the code path would produce; those parameter combinations are the only
ones where the integrated engine deliberately differs from the historical
binaries (20 of 28 496 matrix combinations).

### Module layout

```text
src/deflate/
├── deflate.zig        # version registry (13 releases / 4 classes), dispatch,
│                      # one-shot compressor emulating the wrapper call pattern
├── state.zig          # shared deflate_state, bit output, window, hash,
│                      # longest_match, longest_match_fast (1.2.3-only paths)
├── tables.zig         # configuration_table, static trees, length/distance
│                      # code tables (bit-identical across all versions)
├── trees.zig          # shared trees.c: block flush, tree building, codes
├── stored_legacy.zig  # deflate_stored, zlib 1.2.3-1.2.8  ┐ version-specific
├── stored_1_2_9.zig   # deflate_stored, zlib 1.2.9         ├─ generation
├── stored.zig         # deflate_stored, zlib 1.2.10-1.3.1  ┘ modules
├── fast.zig / slow.zig       # deflate_fast/deflate_slow, zlib 1.2.4+
├── fast_1_2_3.zig / slow_1_2_3.zig  # 1.2.3 variants (strategy dispatch inside)
├── rle.zig            # deflate_rle,   zlib 1.2.4+
└── huff.zig           # deflate_huff,  zlib 1.2.4+
```

---

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/).

```bash
# Native build (Debug)
zig build

# Optimized native build
zig build -Doptimize=ReleaseFast

# Windows x86_64 cross-compilation
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu

# Run unit tests
zig build test

# Run from the build system
zig build run -- <compressed_file>
```

Artifacts are placed in `zig-out/bin/` (`zlib-fingerprint` on POSIX systems,
`zlib-fingerprint.exe` on Windows).

---

## Project Structure

```text
zlib-fingerprint-zig/
├── build.zig              # Build script (zig build)
├── build.zig.zon          # Package manifest
├── src/
│   ├── main.zig           # CLI entry, RFC 1950 header analysis, inflate, output
│   ├── fingerprint.zig    # Three-phase search engine (port of index.ts)
│   ├── profiles.zig       # Profile list, internal/external mode (profiles.ts)
│   ├── ui.zig             # Colored terminal output helpers
│   └── deflate/           # Integrated historical zlib engine (see above)
├── tools/
│   └── zcompress.zig      # Dev tool: compress stdin exactly like the
│                          # historical zlib-<version> wrapper binaries
├── binaries/              # External compressor binaries live here
│   ├── zlib_wrapper.c     # C wrappers compiled against specific zlib versions
│   ├── libdeflate_wrapper.c
│   ├── miniz_wrapper.c
│   ├── zlib_ng_wrapper.c
│   └── download-binaries.sh
└── README.md
```

---

## External binaries setup

In the default mode only the non-zlib profiles need external binaries
(`zlib-ng`, `Zopfli`, `libdeflate`, `miniz` — plus `advdef` for parity).
They are located in the `binaries/` directory **next to the executable**
(the original TypeScript tool resolved `<dist>/../binaries`; the Zig port
uses `<exe_dir>/binaries`).

Build them with the bundled script (works on Linux/macOS and MSYS2 environments):

```bash
cd binaries
./download-binaries.sh
```

On Windows/MSYS2 install the toolchain first:

```bash
pacman -S --needed base-devel unzip mingw-w64-ucrt-x86_64-toolchain mingw-w64-ucrt-x86_64-zlib
```

The C wrappers already include `_setmode(_fileno(stdin/stdout), _O_BINARY)`
for MSYS2/Windows, so byte streams pass through untranslated — required for
bit-exact verification.

> Note: the profile list also contains `AdvanceCOMP 2.6 advdef`, matching the
> original project; as in the original search engine, `advdef` profiles are
> currently never dispatched by the phases (kept for parity).

---

## Usage

```bash
zlib-fingerprint [--verbose | -v] [--external-zlib] <compressed_file>
```

* `--external-zlib` — spawn the historical zlib wrapper binaries
  (`binaries/zlib-<version>`) for stock zlib candidates instead of the
  integrated engine (the original tool's behavior; useful for
  cross-checking). zlib-ng is always external.

The file must contain a zlib stream (RFC 1950). The tool:

1. Prints the parsed zlib header metadata (CF, FLG, window size, FLEVEL hint,
   preset dictionary).
2. Scans the first DEFLATE block (BFINAL/BTYPE).
3. Inflates the stream to recover the raw data.
4. Brute-forces all configured compressor profiles (the integrated engine
   covers all zlib releases 1.2.3–1.3.1):

   * **Phase 1** — trusted metadata: levels 1–2, memLevel 8, strategies 0/1,
     windowBits 15.
   * **Phase 2** — full matrix at windowBits 15: levels 9…1 × memLevels
     8,9,7,6,5 × strategies 0…4 (zlib-type), Zopfli iterations 1…500,
     libdeflate levels 1–12, miniz levels 1–10.
   * **Phase 3** — reduced windows: windowBits 14…8 with the full matrix.

5. Reports the first bit-exact match (implementation, version range, parameters,
   attempt count) or a negative result.

### Example

```text
$ zlib-fingerprint test_p2.zlib
Analyzing zlib stream for: test_p2.zlib

=== Zlib Header Metadata (RFC 1950) ===
- Header Valid (FCHECK) : Yes (OK)
- Compression Method    : 8
- Window Size           : 32768 bytes (windowBits = 15)
- Preset Dictionary     : None
- Compression Level Hint: Default algorithm (2)
========================================

--- Deflate Stream Structure (First blocks scan) ---
- First Block BFINAL : 1
- First Block BTYPE  : 2 (Dynamic Huffman)
--------------------------------------------------

Decompressing stream to extract uncompressed data...
Successfully unpacked: 131072 bytes of raw data.

Starting parameter search across 6 profiles (integrated zlib 1.2.3-1.3.1 engine + 5 external)...

-- Phase 1/3: trusted metadata (levels 1-2, memLevel 8, strategies 0/1, windowBits 15)

-- Phase 2/3: full parameter matrix with the standard window (windowBits 15)

[SUCCESS] Bit-exact match found!
- Implementation: zlib (integrated)
- Binary path: (integrated deflate engine)
- Parameters: level=6, memLevel=8, strategy=1, windowBits=15, zlib 1.2.3-1.3.1 (Phase 2)
- Attempts: 111
```

With `--verbose` / `-v` every attempt is logged (the bracketed suffix names
the covered zlib version range for the current parameter combination):

```text
  [#0001] [Phase 1] zlib (integrated) | lvl=1, mem=8, strat=1, wBits=15 [zlib 1.2.3-1.3.1] -> mismatch
  [#0002] [Phase 1] zlib (integrated) | lvl=1, mem=8, strat=0, wBits=15 [zlib 1.2.3-1.3.1] -> mismatch
  ...
```

---

## Differences from the TypeScript original

| Aspect | TypeScript original | Zig 0.16 port |
|---|---|---|
| Runtime | Node.js ≥ 18 | none (static binary) |
| zlib candidates | external wrapper binaries per version | **integrated engine, zlib 1.2.3–1.3.1** (`--external-zlib` keeps the old behavior) |
| Inflate | `zlib.inflateSync` | `std.compress.flate` (zlib) |
| Subprocess | `child_process.spawnSync` | `std.process.spawn` + feeder thread |
| Mismatch cost | full compression per attempt | early abort at first divergent output chunk |
| Binaries dir | `<dist>/../binaries` | `<exe_dir>/binaries` (only non-zlib profiles) |
| CLI output | plain | colored, live progress, attempt counter |
| Search logic | identical 3 phases, same ordering | identical 3 phases, same ordering (version classes collapsed per combination) |
| Exit codes / messages | — | preserved (usage → 1, not found → 1, inflate failure → 1) |

---

## License

MIT
