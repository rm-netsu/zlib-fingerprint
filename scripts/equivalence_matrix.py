#!/usr/bin/env python3
"""Empirical zlib byte-stream equivalence census using REAL version binaries.

No assumptions about historical release grouping are made. A version's
signature includes return status and exact output for every identical probe.
An equality here is evidence for this finite corpus, not a formal proof.
"""
import argparse
import hashlib
import itertools
import json
import pathlib
import random
import subprocess
import sys
import time


def fixtures():
    rng = random.Random(0x5A4C4942)
    for size in (0, 1, 2, 3, 15, 31, 32, 63, 128, 257, 1024, 4096,
                 8191, 16383, 16384, 32767, 32768, 65535, 65536, 65537,
                 131072, 262144):
        yield f"repeat-{size}", b"A" * size
        yield f"periodic-{size}", (b"abc123\x00\xff" * ((size + 7) // 8))[:size]
        if size <= 65537:
            yield f"random-{size}", rng.randbytes(size)
        if size in (1024, 32768, 65536, 131072):
            yield f"sparse-{size}", bytes(0 if i % 127 else i % 251 for i in range(size))


def parameters(depth):
    if depth == "quick":
        return itertools.product((0, 1, 3, 6, 9), (1, 8, 9), (0, 1, 2, 3, 4), (9, 15))
    return itertools.product(range(10), (1, 4, 8, 9), range(5), (9, 15))


def probe(executable, payload, params, timeout):
    try:
        proc = subprocess.run((str(executable), *map(str, params)), input=payload,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=timeout)
        return proc.returncode, proc.stdout if proc.returncode == 0 else b""
    except subprocess.TimeoutExpired:
        return 124, b""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", default="binaries")
    parser.add_argument("--depth", choices=("quick", "full"), default="quick")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--out", default="equivalence-results.json")
    args = parser.parse_args()
    paths = sorted(path for path in pathlib.Path(args.bin_dir).glob("zlib-*")
                   if path.is_file() and path.stat().st_mode & 0o111)
    if not paths:
        sys.exit("No compiled zlib-* wrappers found")
    names = [p.name.removeprefix("zlib-") for p in paths]
    signatures = [hashlib.sha256() for _ in paths]
    count = 0
    differences = {}
    started = time.monotonic()
    print(f"Testing {len(paths)} releases ({args.depth})", flush=True)

    # A single probe is run for every release before advancing to the next,
    # so the first witnessed difference for each pair is retained.
    for fixture_name, payload in fixtures():
        for params in parameters(args.depth):
            key = (fixture_name, *params)
            results = [probe(p, payload, params, args.timeout) for p in paths]
            digests = []
            for signature, (status, output) in zip(signatures, results):
                one = hashlib.sha256(output).digest()
                signature.update(status.to_bytes(4, "big", signed=True))
                signature.update(len(output).to_bytes(8, "big"))
                signature.update(one)
                digests.append((status, one))
            for i in range(len(paths)):
                for j in range(i + 1, len(paths)):
                    pair = f"{names[i]} / {names[j]}"
                    if pair not in differences and digests[i] != digests[j]:
                        differences[pair] = {
                            "fixture": fixture_name, "params": list(params),
                            "status": [results[i][0], results[j][0]],
                            "lengths": [len(results[i][1]), len(results[j][1])],
                        }
            count += 1
        print(f"{fixture_name}: {count} probes, {time.monotonic()-started:.1f}s", flush=True)

    clusters = {}
    for name, signature in zip(names, signatures):
        clusters.setdefault(signature.hexdigest(), []).append(name)
    report = {
        "matrix": args.depth, "probe_count": count, "versions": names,
        "elapsed_seconds": round(time.monotonic() - started, 2),
        "classes": list(clusters.values()), "first_differences": differences,
        "sha256_by_version": {name: sig.hexdigest() for name, sig in zip(names, signatures)},
        "note": "Finite one-shot Z_FINISH matrix; equality is not a proof for every possible input/call pattern.",
    }
    pathlib.Path(args.out).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("CLASSES:", json.dumps(report["classes"]), flush=True)
    print(f"Saved {args.out}", flush=True)


if __name__ == "__main__":
    main()
