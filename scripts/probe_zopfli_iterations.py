#!/usr/bin/env python3
"""Measure the output coverage added by Zopfli iteration counts not searched.

Runs a bounded deterministic matrix; this is a search-ranking experiment,
not a proof that skipped iterations never make different compressed bytes.
"""
import argparse
import hashlib
import json
import pathlib
import random
import subprocess


def samples(stress=False):
    rng = random.Random(0xC001D00D)
    examples = {
        "repeat-256": b"ABCD" * 64,
        "periodic-1024": (b"abc123\0xyz" * 103)[:1024],
        "random-2048": rng.randbytes(2048),
        "mixed-4096": b"a" * 1024 + rng.randbytes(1024) + b"abc123" * 341 + b"z" * 2,
    }
    if stress:
        words = [rng.randbytes(rng.randrange(3, 60)) for _ in range(512)]
        examples["dictionary-mix-32k"] = b"".join(rng.choice(words) for _ in range(2200))[:32768]
        examples["text-like-64k"] = (
            (b"the quick brown fox jumps over the lazy dog, compressed with zopfli. " * 300)
            + rng.randbytes(8192)
            + (b"ABCDABCDABCE" * 2800)
        )[:65536]
    return examples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="zig-out/bin/zzopfli")
    parser.add_argument("--max-iteration", type=int, default=30)
    parser.add_argument("--stress", action="store_true", help="include larger mixed-pattern fixtures")
    args = parser.parse_args()
    baseline = {1, 2, 3, 5, 10, 15, 50}
    checked = sorted(set(range(1, args.max_iteration + 1)) | {50})
    report = {"baseline": sorted(baseline), "iterations": checked, "fixtures": {}}
    for name, data in samples(args.stress).items():
        outputs = {}
        for iteration in checked:
            result = subprocess.run([args.binary, str(iteration)], input=data,
                                    capture_output=True)
            if result.returncode:
                raise SystemExit(f"compress failed: {name} it={iteration}: {result.stderr[:200]!r}")
            outputs[iteration] = hashlib.sha256(result.stdout).hexdigest()
        distinct = set(outputs.values())
        covered = {outputs[i] for i in baseline if i in outputs}
        marginal = []
        for iteration in checked:
            if iteration not in baseline and outputs[iteration] not in covered:
                marginal.append(iteration)
        result = {"distinct_outputs": len(distinct), "covered_by_baseline": len(covered),
                  "new_iterations": marginal,
                  "output_groups": [[i for i in checked if outputs[i] == digest]
                                    for digest in dict.fromkeys(outputs.values())]}
        report["fixtures"][name] = result
        print(name, result["distinct_outputs"], "unique; uncovered iterations", marginal, flush=True)
    out = pathlib.Path("zopfli-iterations-probe.json")
    out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("saved", out)


if __name__ == "__main__":
    main()
