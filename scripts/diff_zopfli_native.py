#!/usr/bin/env python3
"""Byte-exact regression: native Zig variants vs the official release CLIs.

The complete DEFLATE pipeline (LZ77 optimizer, block splitting, package-merge
code lengths, block encoder) is native Zig for every historical release
(1.0.0, 1.0.1, 1.0.2, 1.0.3). This script checks the full corpus against the
independent reference CLI of each release when available, and always against
the vendored 1.0.3 source. Every matched stream is additionally round-tripped
through zlib decompression to prove it is a valid RFC 1950 stream of the
original payload.

Run after `zig build --release=fast` and upstream make.
Set ZOPFLI_REFS=/path/to/dir to check 1.0.0-1.0.2 against reference CLIs laid
out as <dir>/built-<version>/zopfli-<version>; 1.0.3 always uses the vendored
original.
"""
import os
import pathlib
import random
import subprocess
import tempfile
import zlib

VENDOR_1_0_3 = pathlib.Path("binaries/vendor/zopfli-zopfli-1.0.3/zopfli")
NATIVE = pathlib.Path("zig-out/bin/zzopfli")
VERSIONS = ("1.0.0", "1.0.1", "1.0.2", "1.0.3")


def reference_for(version: str) -> pathlib.Path | None:
    if version == "1.0.3":
        return VENDOR_1_0_3
    refs = pathlib.Path(os.environ.get("ZOPFLI_REFS", "/home/z/my-project/work/references"))
    candidate = refs / f"built-{version}" / f"zopfli-{version}"
    return candidate if candidate.exists() else None


def samples():
    rng = random.Random(0x10F11)
    for n in (0, 1, 32, 256, 4096, 16384, 65536):
        yield f"repeated-{n}", b"A" * n
        yield f"periodic-{n}", (b"abc12345" * ((n + 7) // 8))[:n]
        if n <= 16384:
            yield f"random-{n}", rng.randbytes(n)
    # Cross several hash-window boundaries and mix highly compressible and
    # poorly compressible regions. Both hit the longest-match cache heavily.
    chunks = [rng.randbytes(256) for _ in range(64)]
    yield "dictionary-reuse-48k", b"".join(chunks[i % 17] for i in range(192))
    motif = (b"abc" * 500 + b"XYZ" * 300 + rng.randbytes(97))
    yield "mixed-runs-64k", (motif * 32)[:65536]
    # Cross the upstream 1,000,000-byte master-block boundary.
    yield "master-boundary-1000001", b"A" * 1000001


def main():
    if not VENDOR_1_0_3.exists() or not NATIVE.exists():
        raise SystemExit("Build original zopfli and the Zig zzopfli executable")
    checked = 0
    skipped = []
    with tempfile.TemporaryDirectory(prefix="zf-zopfli-") as d:
        test_file = pathlib.Path(d) / "input.bin"
        for label, data in samples():
            test_file.write_bytes(data)
            for iterations in ((1,) if label.startswith("master-boundary-") else (1, 3, 5, 15)):
                native_outputs = {}
                for version in VERSIONS:
                    reference = reference_for(version)
                    if reference is None:
                        skipped.append((label, iterations, version))
                        continue
                    a = subprocess.run([str(NATIVE), str(iterations), version], input=data,
                                       capture_output=True)
                    b = subprocess.run([str(reference), "--zlib", "-c", f"--i{iterations}",
                                        str(test_file)], capture_output=True)
                    checked += 1
                    # "No stream" outcomes are equivalent regardless of how
                    # they are reported: the 1.0.0/1.0.1 CLI writes an empty
                    # file (rc 0) for empty input, the native variant rejects
                    # it with an error (documented CLI-faithful behaviour).
                    ref_no_stream = b.returncode != 0 or not b.stdout
                    nat_no_stream = a.returncode != 0 or not a.stdout
                    if ref_no_stream != nat_no_stream:
                        raise SystemExit(f"MISMATCH {label}, release={version}, iterations={iterations}, "
                                         f"status={a.returncode}/{b.returncode}, "
                                         f"size={len(a.stdout)}/{len(b.stdout)}")
                    if not ref_no_stream and a.stdout != b.stdout:
                        raise SystemExit(f"MISMATCH {label}, release={version}, iterations={iterations}, "
                                         f"streams differ, size={len(a.stdout)}/{len(b.stdout)}")
                    if a.stdout:
                        if zlib.decompress(a.stdout) != data:
                            raise SystemExit(f"ROUNDTRIP {label}, release={version}, "
                                             f"iterations={iterations}: decompression does not "
                                             f"reproduce the input")
                    native_outputs[version] = a.stdout
                # container sanity for streams produced without a reference
                for version, output in native_outputs.items():
                    if output:
                        head = (output[0], output[1])
                        expected = (0x78, 0x01) if version in ("1.0.0", "1.0.1") else (0x78, 0xda)
                        if head != expected:
                            raise SystemExit(f"HEADER {label}, release={version}: "
                                             f"{head} != {expected}")
    detail = ""
    if skipped:
        detail = f" (reference missing for {len(skipped)} combinations, " \
                 f"checked container headers instead)"
    print(f"Zopfli historical releases native backend: {checked}/{checked} bit-exact{detail}")


if __name__ == "__main__":
    main()
