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

```
