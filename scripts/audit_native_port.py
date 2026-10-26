#!/usr/bin/env python3
"""Version-wide differential audit of native Zig zlib generations.

Reference wrappers are built against the original, individual zlib release.
Both sides receive the same entire input and one final Z_FINISH call. Only
successful streams are byte-compared; capability mismatches are also failures.
This intentionally does not assert parity for other streaming call patterns.
"""
import itertools
import json
import pathlib
import random
import subprocess
import sys

VERSIONS = (
    "1.2.2", "1.2.3", "1.2.4", "1.2.5", "1.2.6", "1.2.7", "1.2.8",
    "1.2.9", "1.2.10", "1.2.11", "1.2.12", "1.2.13", "1.3", "1.3.1", "1.3.2",
)


def fixtures():
    rng = random.Random(0x51AFCAFE)
    yield "empty", b""
    for n in (1, 32, 258, 4096, 16384, 32768, 65535, 65536, 131072, 262144):
        yield f"A-{n}", b"A" * n
        yield f"period-{n}", (b"abc12345\x00\xff" * ((n + 9) // 10))[:n]
        yield f"random-{n}", rng.randbytes(n)
    yield "hash-boundary", (b"A" * 258 + b"B" + b"A" * 257) * 250
    yield "mixed", (b"zlib\0\0" * 1000) + rng.randbytes(10240) + (b"XYZ" * 8192)


def parameters(version):
    # Stored paths vary substantially with memLevel and windowBits.
    for mem, window in itertools.product((1, 8, 9), (9, 15)):
        yield 0, mem, 0, window
    # Fast/slow, default/filtered/Huffman/RLE/fixed across hash/window sizes.
    for level in (1, 3, 6, 9):
        for strategy in (0, 1, 2, 3, 4):
            if version == "1.2.2" and strategy == 4:
                continue  # historical API rejects Z_FIXED
            for mem, window in ((1, 9), (8, 15)):
                yield level, mem, strategy, window


def run(binary, args, data):
    return subprocess.run([str(binary), *map(str, args)], input=data,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main():
    zig = pathlib.Path("zig-out/bin/zcompress")
    if not zig.is_file():
        raise SystemExit("Run zig build -Doptimize=ReleaseFast first")
    inputs = tuple(fixtures())
    result = {"model": "one input, one Z_FINISH, unrestricted output buffer",
              "versions": {}, "mismatches": []}
    for version in VERSIONS:
        oracle = pathlib.Path(f"binaries/zlib-{version}")
        if not oracle.is_file():
            raise SystemExit(f"Missing official reference wrapper: {oracle}")
        counts = {"attempts": 0, "both_success": 0, "both_failure": 0}
        for fixture, (level, mem, strategy, window) in itertools.product(
            inputs, parameters(version)
        ):
            name, data = fixture
            args = (level, mem, strategy, window)
            old = run(oracle, args, data)
            new = run(zig, (version, *args), data)
            counts["attempts"] += 1
            if old.returncode == new.returncode == 0:
                counts["both_success"] += 1
                if old.stdout == new.stdout:
                    continue
                first = next((i for i, (a, b) in enumerate(zip(old.stdout, new.stdout))
                              if a != b), min(len(old.stdout), len(new.stdout)))
                issue = [version, name, args, "bytes", first,
                         len(old.stdout), len(new.stdout)]
            elif (old.returncode == 0) != (new.returncode == 0):
                issue = [version, name, args, "success-status", old.returncode,
                         new.returncode]
            else:
                counts["both_failure"] += 1
                continue
            result["mismatches"].append(issue)
            if len(result["mismatches"]) <= 12:
                print("MISMATCH", issue, flush=True)
        result["versions"][version] = counts
        print(version, counts, flush=True)
    out = pathlib.Path("native-port-audit.json")
    out.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"TOTAL: {sum(v['attempts'] for v in result['versions'].values())} calls; "
          f"{len(result['mismatches'])} mismatches; report {out}", flush=True)
    return 1 if result["mismatches"] else 0


if __name__ == "__main__":
    sys.exit(main())
