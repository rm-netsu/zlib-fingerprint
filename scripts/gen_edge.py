#!/usr/bin/env python3
"""Create edge-case test streams: FDICT-marked and bad-FCHECK headers."""
import zlib

data = open("/bin/ls", "rb").read(20000)

# Stream whose header CLAIMS a preset dictionary (FDICT set, DICTID=0),
# followed by a normal deflate body - enough to exercise the FDICT path.
base = zlib.compress(data, 6)
flg = base[1] | 0x20
# keep FCHECK consistent: recompute check so (cmf*256+flg) % 31 == 0
cmf = base[0]
f = (flg & 0xE0) | 0x1F
while (cmf * 256 + f) % 31 != 0:
    f -= 1
open("/tmp/dict_stream.zlib", "wb").write(bytes([cmf, f]) + b"\x00\x00\x00\x00" + base[2:])

# Corrupt FCHECK: flip the lowest FLG bit of a valid stream.
bad = bytes([base[0], base[1] ^ 1]) + base[2:]
open("/tmp/badcheck.zlib", "wb").write(bad)
print("edge fixtures written")
