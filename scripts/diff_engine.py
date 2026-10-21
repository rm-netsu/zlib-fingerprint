#!/usr/bin/env python3
"""Differential verification harness for the integrated deflate engine.

For every available one-shot zlib wrapper binary and a matrix of
parameters/payloads, compares the integrated engine's output (via the
zcompress dev tool) against the real zlib build's output byte-for-byte.
Level 0 (stored) is the critical class: its block layout is both
input-flush-pattern- and avail_out-dependent.
"""
import os
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BIN = os.path.join(ROOT, "binaries")
ZCOMPRESS = os.path.join(ROOT, "zig-out", "bin", "zcompress")

VERSIONS = ["1.2.3", "1.2.5", "1.2.7", "1.2.8", "1.2.11", "1.2.12", "1.2.13", "1.3", "1.3.1"]

import zlib, random
random.seed(20261021)
rnd = bytes(random.randrange(256) for _ in range(100_000))
payloads = {
    "empty": b"",
    "text4000": (b"The quick brown fox jumps over the lazy dog. " * 120)[:4000],
    "stored178k": open("/tmp/payload.bin", "rb").read() if os.path.exists("/tmp/payload.bin") else bytes(range(256)) * 700,
    "random100k": rnd,
    "repeat300k": b"ab" * 150_000,
    "bin330k": open("/bin/ls", "rb").read() * 4,
}

fails = 0
runs = 0


def check(version, level, mem, strat, wb, payload):
    global fails, runs
    p_ref = subprocess.run([os.path.join(BIN, f"zlib-{version}"), str(level), str(mem), str(strat), str(wb)],
                           input=payload, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    p_eng = subprocess.run([ZCOMPRESS, version, str(level), str(mem), str(strat), str(wb)],
                           input=payload, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    runs += 1
    if p_ref.returncode != 0 or p_eng.returncode != 0:
        print(f"FAIL(spawn) zlib-{version} l={level} m={mem} s={strat} w={wb} "
              f"payload={len(payload)}B rc_ref={p_ref.returncode} rc_eng={p_eng.returncode}")
        fails += 1
        return
    if p_ref.stdout != p_eng.stdout:
        print(f"FAIL(zlib-{version} l={level} m={mem} s={strat} w={wb} payload={len(payload)}B): "
              f"ref={len(p_ref.stdout)}B engine={len(p_eng.stdout)}B")
        fails += 1


for v in VERSIONS:
    for payload_name, payload in payloads.items():
        # Level 0: full coverage (stored layout is the sensitive one).
        for mem in (1, 8, 9):
            for wb in (9, 15):
                check(v, 0, mem, 0, wb, payload)
        # Levels 1-9 spot checks: call pattern is byte-neutral there.
        for level, strat in ((1, 0), (6, 0), (9, 0), (6, 1), (9, 2), (9, 3), (6, 4)):
            check(v, level, 8, strat, 15, payload)
            check(v, level, 9, strat, 15, payload)

print(f"\n{runs - fails}/{runs} identical" + ("" if fails == 0 else f", {fails} MISMATCHES"))
sys.exit(1 if fails else 0)
