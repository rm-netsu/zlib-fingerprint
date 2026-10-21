#!/usr/bin/env python3
"""Benchmark: run the new Zig engine over every fixture and report the
attempt index at which the bit-exact match was found."""
import os
import re
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TOOL = os.path.join(ROOT, "zig-out", "bin", "zlib-fingerprint")
FIXTURES = os.path.join(ROOT, "fixtures")

rows = []
for name in sorted(os.listdir(FIXTURES)):
    if not name.endswith(".zlib"):
        continue
    path = os.path.join(FIXTURES, name)
    p = subprocess.run([TOOL, "--binaries", os.path.join(ROOT, "binaries"), path],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    out = p.stdout
    m = re.search(r"Convergence\s*:\s*(\d+) attempts?, ([\d.]+) ms", out)
    impl = re.search(r"- Implementation: (.+)", out)
    stage = re.search(r"- Stage\s+: (.+)", out)
    hdr = open(path, "rb").read(2).hex()
    rows.append((
        name,
        hdr,
        impl.group(1).strip() if impl else "-",
        stage.group(1).split(":")[0].strip() if stage else "-",
        int(m.group(1)) if m else -1,
        float(m.group(2)) if m else -1.0,
        p.returncode,
    ))

print(f"{'fixture':18s} {'hdr':5s} {'implementation':20s} {'stage':5s} {'attempts':>8s} {'ms':>8s}  rc")
for name, hdr, impl, stage, att, ms, rc in rows:
    print(f"{name:18s} {hdr:5s} {impl:20s} {stage:5s} {att:8d} {ms:8.1f}  {rc}")
ok = sum(1 for r in rows if r[6] == 0)
print(f"\n{ok}/{len(rows)} matched")
