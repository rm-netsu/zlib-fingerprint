#!/usr/bin/env python3
"""Follow-up analysis of stream-matrix.json: pin down exact witnesses."""
import importlib.util
import json
import subprocess

spec = importlib.util.spec_from_file_location("sm", "scripts/stream_matrix.py")
sm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)
fx = sm.fixtures()
S = sm.scenarios(fx)


def run(ver, args, data):
    p = subprocess.run([f"binaries/zstream-{ver}"] + args, input=data,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.returncode, p.stdout


print("=== H split hunting (level 0, repeat-65535, outchunk sweep):")
for outc in (1, 2, 3, 4, 5, 8, 16, 32, 64, 128, 512, 4096):
    outs = {}
    for ver in ("1.2.9", "1.2.10", "1.2.11", "1.2.12", "1.2.13", "1.4"):
        rc, out = run(ver, ["one", "0", "8", "0", "15", "0", str(outc)],
                      fx["repeat-65535"])
        outs[ver] = (rc, out)
    sigs = {}
    for v, o in outs.items():
        sigs.setdefault((o[0], o[1]), []).append(v)
    if len(sigs) > 1:
        groups = [members for members in sigs.values()]
        lens = {v: len(o[1]) for v, o in outs.items()}
        print(f"  outchunk={outc:5d}: groups={groups} lens={lens}")

print("\n=== A byte-diff where both 1.0.1 and 1.0.4 succeed:")
cnt = 0
for scn in S:
    if scn["group"] not in ("chunk", "every", "flush"):
        continue
    payload = fx[scn["fixture"]]
    rc1, o1 = run("1.0.1", scn["args"], payload)
    rc4, o4 = run("1.0.4", scn["args"], payload)
    if rc1 == 0 and rc4 == 0 and o1 != o4:
        cnt += 1
        if cnt <= 5:
            print(f"  {scn['group']}/{scn['fixture']} args={scn['args']} "
                  f"lens {len(o1)} vs {len(o4)}")
print(f"  total byte-diff scenarios: {cnt}")

r = json.load(open("stream-matrix.json"))
from collections import Counter
c = Counter()
for f in r["roundtrip_failures"]:
    c[(f["group"], f["args"][0], tuple(f["args"][1:6]))] += 1
print("\n=== roundtrip failure signatures (mode, level..outchunk):")
for k, v in c.most_common(15):
    print(" ", k, v)
