#!/usr/bin/env python3
"""Differential verification of the native miniz tdefl port (src/miniz/)
against the reference miniz-3.1.2 wrapper binary (binaries/miniz-3.1.2).

For every (fixture, level) combination it asserts that the native engine
(zig-out/bin/zminiz) reproduces the reference wrapper's output byte for
byte, and that both streams round-trip through zlib decompression.

Usage:  python3 scripts/diff_native_miniz.py [--jobs N]
Exit code 0 iff every comparison passes."""
import argparse
import concurrent.futures
import pathlib
import random
import subprocess
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
NATIVE = ROOT / "zig-out" / "bin" / "zminiz"
ORACLE = ROOT / "binaries" / "miniz-3.1.2"


def fixtures():
    rng = random.Random(1337)
    cases = {
        "empty": b"",
        "one": b"a",
        "two": b"ab",
        "three": b"abc",
        "short-text": b"hello world! ",
        "text-64": b"The quick brown fox jumps over the lazy dog. " * 2,
        "text-4k": (b"The quick brown fox jumps over the lazy dog. " * 100)[:4096],
        "text-100k": (b"Lorem ipsum dolor sit amet, consectetur adipiscing elit. " * 2000)[:100000],
        "repeat-65535": b"\x41" * 65535,
        "repeat-258": b"\x00" * 258,
        "repeat-257": b"\xff" * 257,
        "binary-rnd-1k": bytes(rng.randrange(256) for _ in range(1024)),
        "binary-rnd-100k": bytes(rng.randrange(256) for _ in range(100000)),
        "mixed-70k": (bytes(rng.randrange(65, 91) for _ in range(1024)) + b"\x00" * 1024 + b"ab" * 512) * 25,
        "periodic-1000": (b"\x01\x02\x03\x04" * 250)[:1000],
        "nulls-70k": b"\x00" * 70000,
        "abc-runs": b"abcabcabc" * 8000,
        "near-31k": (b"xyz" * 10300)[:31000],
        "incompressible-40k": bytes(rng.randrange(256) for _ in range(40000)),
        "lowent-70k": bytes(rng.choice(b"ab") for _ in range(70000)),
    }
    for name, data in cases.items():
        for level in range(0, 11):
            yield name, data, level
    # Randomized stress cases.
    for trial in range(120):
        kind = trial % 5
        if kind == 0:
            size = rng.choice([1, 2, 3, 7, 50, 300, 5000, 33333, 70000, 150000])
            data = bytes(rng.randrange(256) for _ in range(size))
        elif kind == 1:
            data = bytes(rng.choice(b"ab") for _ in range(rng.choice([100, 10000, 66666])))
        elif kind == 2:
            p = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 40)))
            data = (p * (rng.randrange(100, 6000) // max(1, len(p)) + 1))[: rng.choice([1000, 32768, 66000])]
        elif kind == 3:
            words = [bytes(rng.choice(b"abcdefghijklmnopqrstuvwxyz ") for _ in range(rng.randrange(2, 9))) for _ in range(30)]
            data = b" ".join(rng.choice(words) for _ in range(rng.randrange(10, 9000)))[: rng.choice([500, 40000, 90000])]
        else:
            data = b"".join(bytes([rng.randrange(256)]) * rng.randrange(1, 5000) for _ in range(rng.randrange(1, 60)))
        yield f"stress-{trial}", data, rng.randrange(0, 11)


def run(case):
    name, data, level = case
    argv = [str(level)]
    native = subprocess.run([str(NATIVE)] + argv, input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=300).stdout
    if not ORACLE.exists():
        return name, level, "skip-oracle", native
    oracle = subprocess.run([str(ORACLE)] + argv, input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=300).stdout
    if native != oracle:
        return name, level, "mismatch", native
    try:
        if zlib.decompress(native) != data:
            return name, level, "roundtrip", native
    except zlib.error:
        return name, level, "corrupt", native
    return name, level, "ok", native


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()

    cases = list(fixtures())
    failures = []
    passed = skipped = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for name, level, status, _ in pool.map(run, cases):
            if status == "ok":
                passed += 1
            elif status == "skip-oracle":
                skipped += 1
            else:
                failures.append((name, level, status))

    print(f"miniz native: {passed} passed, {skipped} skipped (no oracle), {len(failures)} failed")
    for name, level, status in failures:
        print(f"  FAIL {name} level={level}: {status}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
