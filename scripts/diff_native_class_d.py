#!/usr/bin/env python3
"""Compare class D's native Zig path with the original zlib 1.2.2 oracle.

This tests one-shot successful outputs and capability rejection independently.
It deliberately does not claim equivalence for streaming API call patterns.
"""
import itertools
import pathlib
import random
import subprocess


def samples():
    rng = random.Random(0xD122)
    for n in (0, 1, 2, 32, 257, 1024, 4096, 16384, 32768, 65535, 65536, 131072):
        yield f"repeated-{n}", b"A" * n
        yield f"periodic-{n}", (b"abc123\x00\xff" * ((n + 7) // 8))[:n]
        yield f"random-{n}", rng.randbytes(n)


def main():
    native = pathlib.Path("zig-out/bin/zcompress")
    original = pathlib.Path("binaries/zlib-1.2.2")
    if not native.exists() or not original.exists():
        raise SystemExit("build zcompress and the original zlib-1.2.2 binary first")

    checked = 0
    both_ok = 0
    errors = []
    for (name, data), (level, mem, strategy, window) in itertools.product(
        samples(), itertools.product((0, 1, 3, 6, 9), (1, 8), (0, 1, 2, 3, 4), (9, 15))
    ):
        # The original C level-0/huffman/rle paths may corrupt heap memory.
        if level == 0 and strategy >= 2:
            continue
        params = [str(level), str(mem), str(strategy), str(window)]
        a = subprocess.run([native, "1.2.2", *params], input=data, capture_output=True)
        b = subprocess.run([original, *params], input=data, capture_output=True)
        checked += 1
        if a.returncode == b.returncode == 0:
            both_ok += 1
            if a.stdout != b.stdout:
                errors.append((name, params, len(a.stdout), len(b.stdout)))
        elif (a.returncode == 0) != (b.returncode == 0):
            errors.append((name, params, a.returncode, b.returncode))
        if len(errors) >= 10:
            break
    print(f"class D: {checked} comparisons, {both_ok} common-success streams")
    if errors:
        print("MISMATCHES:", errors)
        raise SystemExit(1)
    print("Class D native Zig path matches original 1.2.2 for all tested safe cases")


if __name__ == "__main__":
    main()
