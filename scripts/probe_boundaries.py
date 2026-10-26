#!/usr/bin/env python3
"""Find successful-output witnesses for class boundaries across avail_out sizes."""
import itertools
import json
import pathlib
import subprocess

PAIRS = (("1.0.5", "1.0.6"), ("1.0.9", "1.1.0"),
         ("1.2.0", "1.2.1"), ("1.2.2", "1.2.3"),
         ("1.2.3", "1.2.4"), ("1.2.8", "1.2.9"),
         ("1.2.9", "1.2.10"), ("1.3.1", "1.3.2"))


def run(version, payload, level, mem, strategy, wb, chunk):
    p = subprocess.run((f"binaries/zlib-{version}", str(level), str(mem),
                        str(strategy), str(wb), str(chunk)), input=payload,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return (p.returncode, p.stdout)


def main():
    payloads = [
        ("empty", b""), ("repeat-32", b"A" * 32),
        ("periodic-1024", b"abcdefgh" * 128),
        ("repeat-65535", b"A" * 65535),
        ("periodic-65536", b"abc12345" * 8192),
        ("repeat-131072", b"A" * 131072),
        ("periodic-262144", b"abc12345" * 32768),
    ]
    witnesses = {}
    for a, b in PAIRS:
        print(f"Checking {a} vs {b}", flush=True)
        record = {"output": None, "api": None, "shared_successes": 0}
        for (name, payload), (level, mem, strat, wb, chunk) in itertools.product(
                payloads, itertools.product((0, 1, 6, 9), (1, 8), (0, 2, 3),
                                            (9, 15), (64, 1024, 32768, 0))):
            ra, oa = run(a, payload, level, mem, strat, wb, chunk)
            rb, ob = run(b, payload, level, mem, strat, wb, chunk)
            key = {"fixture": name, "level": level, "mem": mem,
                   "strategy": strat, "window": wb, "out_chunk": chunk,
                   "status": [ra, rb], "length": [len(oa), len(ob)]}
            if ra == rb == 0:
                record["shared_successes"] += 1
                if oa != ob and record["output"] is None:
                    record["output"] = key
            elif ra != rb and record["api"] is None:
                record["api"] = key
        witnesses[f"{a} / {b}"] = record
        print(json.dumps(record), flush=True)
    pathlib.Path("boundary-results.json").write_text(
        json.dumps(witnesses, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
