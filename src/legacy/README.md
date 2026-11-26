# Historical in-process zlib cores (differential oracles)

The four C source snapshots under `vendor/` are taken from official zlib
release source distributions and retain their original copyright and
license notices (`zlib.h`). They are intentionally not altered: all exported
symbols are renamed at compile time by `build.zig` so all four versions can
be linked into the same program.

| Class | Source release | Covered empirical group |
|---|---|---|
| A | zlib 1.0.5 | 1.0.1, 1.0.2, 1.0.4, 1.0.5 |
| B | zlib 1.0.9 | 1.0.6–1.0.9 |
| C | zlib 1.2.0 | 1.1.0–1.1.4 and 1.2.0 |
| D | zlib 1.2.2 | 1.2.1–1.2.2 |

**Role since the native port (2026-11-25):** every class — D as well as
A-C — runs through the shared native Zig deflate engine inside the
fingerprint search (`src/deflate/`, class-specific variants). These C cores
are no longer part of the `zlib-fingerprint` executable; they are compiled
only into the `zlegacy` dev tool, where they serve as independent
differential oracles for `scripts/diff_legacy_native.py` and
`scripts/diff_native_legacy.py` (43,619 comparisons, zero mismatches,
including byte-exact checks against all 16 official class-member release
binaries).

`bridge.c` mirrors the one-shot stdin-to-stdout reference wrapper, allocating
a sufficiently large output buffer before one `Z_FINISH` call. `legacy.zig`
selects the appropriate class at runtime. The C snapshots are compiled from
source as part of `zig build` (for `zlegacy`), so no runtime zlib libraries,
DLLs, or external executables are required for the differential tooling.

The historical C source has memory-unsafe corner cases, faithfully preserved:

* class A level 0 with memLevel < 8 — the 0xffff-clamped stored block
  overruns the pending buffer and the original aborts;
* classes A/B windowBits 8 at level >= 1 — MAX_DIST underflows and the match
  finder follows stale hash chains with wrapped distances into
  out-of-bounds reads (at level 0 the same parameters produce a
  deterministic, data-losing stream that the native port reproduces
  byte-exactly);
* class C rejects windowBits 8 and strategies above Z_HUFFMAN_ONLY.

The fingerprint search never probes those paths in-process; the external
audit mode (`--external-zlib`) isolates them in child processes. The
remaining sanitizer work is tracked in `BACKLOG.md`.

Reference sources: `https://zlib.net/fossils/` (1.0.5, 1.0.9) and the
upstream zlib release tags (1.2.0, 1.2.2). Every original notice is kept.
The vendor copies were verified byte-identical to the upstream fossils
(`diff` against `zlib.net/fossils/zlib-1.0.5.tar.gz`).
