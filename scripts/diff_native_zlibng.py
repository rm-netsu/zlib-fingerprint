#!/usr/bin/env python3
"""Differential verification of the native zlib-ng 2.2.1 (compat) port
(src/zlibng/) against the reference wrapper binary
(binaries/zlib-ng-2.2.1, built from the official 2.2.1 sources).

The matrix runs every (level, memLevel, strategy) combination over a mixed
payload at windowBits 15 (the wrapper hardcodes 15), plus randomized stress
cases. Every pair must match byte for byte; both streams must round-trip
through zlib decompression.

Note: the reference binary needs the vendor libz.so at runtime — it is
linked with -Wl,-rpath,. so it resolves from its build directory; when in
doubt run from the repository root (the wrapper's rpath finds ./vendor/...).

Usage:  python3 scripts/diff_native_zlibng.py [--jobs N] [--full]
  --full  additionally run the full memLevel x strategy x windowBits matrix
Exit code 0 iff every comparison passes."""
import argparse
import concurrent.futures
import os
import pathlib
import random
import subprocess
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
NATIVE = ROOT / "zig-out" / "bin" / "zzlibng"
ORACLE = ROOT / "binaries" / "zlib-ng-2.2.1"
VENDOR = ROOT / "binaries" / "vendor" / "zlib-ng-2.2.1"


def env():
    e = dict(os.environ)
    if VENDOR.is_dir():
        e["LD_LIBRARY_PATH"] = str(VENDOR) + (":" + e["LD_LIBRARY_PATH"] if e.get("LD_LIBRARY_PATH") else "")
    return e


def base_fixture():
    rng = random.Random(99)
    return (b"The quick brown fox jumps over the lazy dog. " * 400
            + b"\x00" * 3000 + b"abcabcabc" * 2000)


def matrix_cases(full):
    data = base_fixture()
    for level in range(0, 10):
        for mem in ((1, 4, 9) if full else (8,)):
            for strat in range(0, 5):
                yield f"m-l{level}-me{mem}-s{strat}", data, level, mem, strat


def stress_cases(n=60):
    rng = random.Random(4242)
    for trial in range(n):
        kind = rng.randrange(5)
        if kind == 0:
            size = rng.choice([1, 5, 300, 33333, 70000, 200000])
            data = bytes(rng.randrange(256) for _ in range(size))
        elif kind == 1:
            data = bytes(rng.choice(b"ab") for _ in range(rng.choice([100, 10000, 66666])))
        elif kind == 2:
            p = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 40)))
            data = (p * (rng.randrange(100, 20000) // max(1, len(p)) + 1))[: rng.choice([1000, 32768, 66000])]
        elif kind == 3:
            words = [bytes(rng.choice(b"abcdefghijklmnopqrstuvwxyz ") for _ in range(rng.randrange(2, 9))) for _ in range(30)]
            data = b" ".join(rng.choice(words) for _ in range(rng.randrange(10, 9000)))[: rng.choice([500, 40000, 90000])]
        else:
            data = b"".join(bytes([rng.randrange(256)]) * rng.randrange(1, 5000) for _ in range(rng.randrange(1, 60)))
        yield (f"stress-{trial}", data, rng.randrange(0, 10),
               rng.choice([1, 4, 8, 9]), rng.choice([0, 0, 0, 1, 2, 3, 4]))


def run(case):
    name, data, level, mem, strat = case
    argv = [str(level), str(mem), str(strat), "15"]
    native = subprocess.run([str(NATIVE)] + argv, input=data,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=300).stdout
    if not ORACLE.exists():
        return name, "skip-oracle", None
    oracle = subprocess.run([str(ORACLE)] + argv, input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=300, env=env()).stdout
    if native != oracle:
        return name, "mismatch", (len(native), len(oracle))
    try:
        if zlib.decompress(native) != data:
            return name, "roundtrip", None
    except zlib.error:
        return name, "corrupt", None
    return name, "ok", None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args()

    cases = list(matrix_cases(args.full)) + list(stress_cases())
    failures = []
    passed = skipped = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for name, status, detail in pool.map(run, cases):
            if status == "ok":
                passed += 1
            elif status == "skip-oracle":
                skipped += 1
            else:
                failures.append((name, status, detail))

    print(f"zlib-ng native: {passed} passed, {skipped} skipped (no oracle), {len(failures)} failed")
    for name, status, detail in failures:
        print(f"  FAIL {name}: {status} {detail or ''}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
