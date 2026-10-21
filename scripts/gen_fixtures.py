#!/usr/bin/env python3
"""Generate zlib stream fixtures covering every FLEVEL / strategy / window
class, for the convergence benchmark of the metadata-driven search engine."""
import os
import zlib
import subprocess

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "binaries")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures")
os.makedirs(OUT, exist_ok=True)

with open("/bin/ls", "rb") as f:
    data = f.read()
with open("/usr/lib/x86_64-linux-gnu/libc.so.6", "rb") as f:
    data += f.read(20000)

text = (b"The quick brown fox jumps over the lazy dog. " * 120)
data2 = text[:4000] + data[:4000]


def run(binary, args, inp):
    p = subprocess.run([os.path.join(BIN, binary)] + args,
                       input=inp, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.stdout if p.returncode == 0 else None


fixtures = []


def save(name, blob):
    path = os.path.join(OUT, name + ".zlib")
    with open(path, "wb") as f:
        f.write(blob)
    fixtures.append((name, path, len(blob)))


# --- zlib classes (python 3.12 links zlib 1.3.x) ---
save("z_default", zlib.compress(data))                       # level 6, 0x789C
save("z_l9", zlib.compress(data, 9))                         # 0x78DA
save("z_l1", zlib.compress(data, 1))                         # 0x7801
save("z_l2", zlib.compress(data, 2))                         # 0x785E
save("z_l5", zlib.compress(data, 5))                         # 0x785E
save("z_l8", zlib.compress(data, 8))                         # 0x78DA
co = zlib.compressobj(6, zlib.DEFLATED, 15, 8, zlib.Z_FILTERED)
save("z_filtered", co.compress(data) + co.flush())           # 0x789C
co = zlib.compressobj(6, zlib.DEFLATED, 15, 8, zlib.Z_HUFFMAN_ONLY)
save("z_huffman", co.compress(data) + co.flush())            # 0x7801
co = zlib.compressobj(6, zlib.DEFLATED, 15, 8, zlib.Z_RLE)
save("z_rle", co.compress(data) + co.flush())                # 0x7801
co = zlib.compressobj(6, zlib.DEFLATED, 15, 8, zlib.Z_FIXED)
save("z_fixed", co.compress(data) + co.flush())              # 0x7801
co = zlib.compressobj(6, zlib.DEFLATED, 12, 8, 0)
save("z_w12", co.compress(data) + co.flush())                # 0x4889
co = zlib.compressobj(6, zlib.DEFLATED, 15, 9, 0)
save("z_mem9", co.compress(data) + co.flush())               # 0x789C
save("z_stored", run("zlib-1.3.1", ["0", "8", "0", "15"], data) or b"")  # 0x7801, BTYPE=0
save("z_small_default", zlib.compress(data2))                # small default

# --- other implementations (via wrappers) ---
out = run("zlib-ng-2.2.1", ["6", "8", "0", "15"], data)
if out:
    save("ng_default", out)

for it in (1, 15):
    out = run("zopfli-1.0.3", ["--zlib", "-c", f"--i{it}", "/dev/stdin"], data)
    if not out:
        # zopfli needs a real file
        tmp = "/tmp/zf-fixture-in.bin"
        with open(tmp, "wb") as f:
            f.write(data)
        out = run("zopfli-1.0.3", ["--zlib", "-c", f"--i{it}", tmp], b"")
    if out:
        save(f"zopfli_i{it}", out)

for lvl in (1, 6, 12):
    out = run("libdeflate-1.20", [str(lvl)], data)
    if out:
        save(f"ld_l{lvl}", out)

for lvl in (1, 6, 10):
    out = run("miniz-3.1.2", [str(lvl)], data)
    if out:
        save(f"mz_l{lvl}", out)

for name, path, clen in fixtures:
    with open(path, "rb") as f:
        hdr = f.read(2).hex()
    print(f"{name:16s} header={hdr} size={clen}")
print(f"\n{len(fixtures)} fixtures written to {OUT}")
