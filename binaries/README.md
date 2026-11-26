# Binaries Directory (`binaries/`)

This directory stores precompiled executable binaries of various compression implementations and versions.

## Naming Convention

To ensure precise tracking and avoid discrepancies between different releases, all binaries placed in this folder **must** follow the strict naming convention:

```text
<implementation-name>-<major>.<minor>.<patch>

```

**Examples:**

* `zlib-1.2.8` — official zlib version 1.2.8 wrapper.
* `zlib-1.3.1` — official zlib version 1.3.1 wrapper.
* `zlib-ng-2.1.6` — zlib-ng implementation version 2.1.6.
* `zopfli-1.0.3` — Google Zopfli version 1.0.3.

---

## Expected Binary Behavior

1. **Input:** Read raw uncompressed data from **Standard Input (`stdin`)**.
2. **Output:** Write the compressed stream to **Standard Output (`stdout`)**.
3. **Arguments:** Accept the compression level as a command-line argument.

---

## Compiling a Specific Version (C Wrapper Example)

When compiling a specific version of official zlib (e.g., `1.2.8`), name the output binary accordingly:

```bash
gcc -O3 zlib_wrapper.c -lz -o zlib-1.2.8
```

## zlib reference wrappers (zlib-<ver> / zstream-<ver>)

The official stock-zlib wrappers for every release 1.0.1-1.4 are
the differential-testing oracles of the **zlib-replicant** engine package:
their wrapper sources (`zlib_wrapper.c`, `zstream_wrapper.c`)
and the build recipe live there, and `build-binaries.sh` delegates
the whole family to the package's `zlib-replicant/binaries/build-references.sh`
with `OUT_DIR`/`VENDOR_DIR` pointing here. `ZLIB_ONLY=1 bash build-binaries.sh`
builds just this family.

---

## Oracle notes (native ports)

Since the native zlib-ng and miniz ports landed, their reference binaries
in this directory are **differential oracles** for the in-process engines
(`zig-out/bin/zzlibng`, `zig-out/bin/zminiz`):

* `miniz-3.1.2` — self-contained (statically compiled amalgamation).
* `zlib-ng-2.2.1` — links the vendor `libz.so`; built with
  `-Wl,-rpath,.` from the vendor directory. Run it with
  `LD_LIBRARY_PATH=binaries/vendor/zlib-ng-2.2.1` (the differential
  scripts `scripts/diff_native_*.py` set this automatically).

The wrapper `zlib_ng_wrapper.c` hardcodes windowBits=15 (its fourth
argument is accepted but ignored); `zzlibng` mirrors this exactly.
