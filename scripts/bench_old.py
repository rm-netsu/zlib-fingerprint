#!/usr/bin/env python3
"""Benchmark the ORIGINAL TypeScript engine (bun) over the fixtures and
report the attempt count until the bit-exact match, for comparison with
the metadata-driven Zig engine."""
import os
import re
import shutil
import subprocess
import sys

ROOT = "/home/z/my-project"
WORK = os.path.join(ROOT, "work")
NEW = os.path.join(ROOT, "zlib-fingerprint-zig")
BIN = os.path.join(NEW, "binaries")

# The TS tool expects binaries in work/binaries — mirror them.
for f in os.listdir(BIN):
    src = os.path.join(BIN, f)
    dst = os.path.join(WORK, "binaries", f)
    if os.path.isfile(src) and os.access(src, os.X_OK):
        if not os.path.exists(dst):
            shutil.copy2(src, dst)

SKIP = {"zopfli_i1.zlib", "zopfli_i15.zlib"}  # broken profile in TS original

rows = []
for name in sorted(os.listdir(os.path.join(NEW, "fixtures"))):
    if not name.endswith(".zlib") or name in SKIP:
        continue
    path = os.path.join(NEW, "fixtures", name)
    try:
        p = subprocess.run(["bun", os.path.join(WORK, "bin", "cli.js"), "--verbose", path],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, timeout=420)
        out = p.stdout
        attempts = out.count("[Attempt]")
        matched = "MATCH FOUND" in out
        impl = re.search(r"- Implementation: (.+)", out)
        rows.append((name, attempts, matched, impl.group(1).strip() if impl else "-"))
    except subprocess.TimeoutExpired:
        rows.append((name, -1, False, "TIMEOUT"))

print(f"{'fixture':18s} {'attempts':>8s}  matched  implementation")
for name, att, matched, impl in rows:
    print(f"{name:18s} {att:8d}  {str(matched):7s}  {impl}")
