# Historical in-process zlib cores

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

Class D has also been moved to the shared native Zig deflate engine under the
`v1_2_2` version entry, retaining the original C class-D build as a reference
oracle for differential testing. Classes A-C still execute these C cores in
the default fingerprint search and **have not yet been ported to Zig**.

`bridge.c` mirrors the one-shot stdin-to-stdout reference wrapper, allocating
a sufficiently large output buffer before one `Z_FINISH` call. `legacy.zig`
selects the appropriate class at runtime. The C snapshots are compiled from
source as part of `zig build`, so no runtime zlib libraries, DLLs, or external
executables are required for these four classes.

The historical C source has memory-unsafe corner cases. `fingerprint.zig`
skips known risky level-0/strategy combinations when probing in-process;
the audit path `--external-zlib` can isolate these in child processes. The
remaining sanitizer work is tracked in `BACKLOG.md`.

Reference sources: `https://zlib.net/fossils/` (1.0.5, 1.0.9) and the
upstream zlib release tags (1.2.0, 1.2.2). Every original notice is kept.
