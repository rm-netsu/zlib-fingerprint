#!/usr/bin/env python3
"""Check statically linked class A-D cores against genuine release binaries."""
import itertools
import pathlib
import random
import subprocess

REPRESENTATIVES = {"a": "1.0.5", "b": "1.0.9", "c": "1.2.0", "d": "1.2.2"}


def fixtures():
    rng = random.Random(0xABCD1234)
    for n in (0, 1, 2, 32, 257, 1024, 4096, 32768, 65535, 65536, 131072):
        yield f"repeat-{n}", b"A" * n
        yield f"periodic-{n}", (b"abc123\x00\xff" * ((n + 7) // 8))[:n]
        if n <= 65536:
            yield f"random-{n}", rng.randbytes(n)


def main():
    tested = 0
    skipped = 0
    mismatch = []
    for group, version in REPRESENTATIVES.items():
        native = pathlib.Path("zig-out/bin/zlegacy")
        historical = pathlib.Path(f"binaries/zlib-{version}")
        if not native.exists() or not historical.exists():
            raise SystemExit("Build zlegacy and historical binaries before this comparison")
        for name, payload in fixtures():
            for level, mem, strategy, wb in itertools.product(
                    (0, 1, 3, 6, 9), (1, 8), (0, 1, 2, 3), (9, 15)):
                if level == 0 and strategy >= 2 or group == "a" and level == 0 and mem < 8:
                    skipped += 1  # Memory-unsafe original C paths.
                    continue
                params = [str(p) for p in (level, mem, strategy, wb)]
                a = subprocess.run([str(native), group, *params], input=payload, capture_output=True)
                b = subprocess.run([str(historical), *params], input=payload, capture_output=True)
                tested += 1
                if a.returncode != b.returncode and (a.returncode == 0 or b.returncode == 0):
                    mismatch.append((group, name, params, a.returncode, b.returncode))
                elif a.returncode == b.returncode == 0 and a.stdout != b.stdout:
                    mismatch.append((group, name, params, len(a.stdout), len(b.stdout)))
                if len(mismatch) >= 15:
                    print("MISMATCHES:", mismatch)
                    raise SystemExit(1)
        print(f"class {group}: tested", flush=True)
    print(f"Native/reference comparisons: {tested}; unsafe probes skipped: {skipped}")
    if mismatch:
        print("MISMATCHES:", mismatch)
        raise SystemExit(1)
    print("All tested successful outputs bit-exact")


if __name__ == "__main__":
    main()
