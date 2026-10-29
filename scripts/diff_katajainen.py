#!/usr/bin/env python3
"""Byte-exact differential test: native Zig katajainen.zig vs the ORIGINAL
upstream Zopfli 1.0.3 katajainen.c.

Corpus (all deterministic, fixed seeds):
  - empty and minimal frequency sets (0, 1, 2 used symbols);
  - equal frequencies over whole alphabets;
  - skewed distributions (powers of two, Fibonacci, one-heavy-symbol);
  - boundary cases: numsymbols == 2^maxbits and 2^maxbits + 1;
  - maxbits above numsymbols - 1 (limit reduction path);
  - alphabets of 19, 30, 32 and 288 symbols at DEFLATE limits;
  - pseudo-random vectors across n in [0, 288] and maxbits in [1, 15];
  - large weights up to 10^6 and the 2^55 rejection boundary.

Run after `zig build` (the zkatajainen tool is built by default).
"""
import pathlib
import random
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
NATIVE = ROOT / "zig-out" / "bin" / "zkatajainen"
REF_SRC = ROOT / "scripts" / "katajainen_ref.c"
VENDOR = ROOT / "binaries" / "vendor" / "zopfli-zopfli-1.0.3" / "src" / "zopfli"
REF_BIN = ROOT / "scripts" / "katajainen_ref"


def build_reference() -> None:
    subprocess.run(
        ["cc", "-O2", f"-I{VENDOR}", str(REF_SRC), str(VENDOR / "katajainen.c"),
         "-o", str(REF_BIN)],
        check=True,
    )


def encode(n: int, maxbits: int, freqs) -> bytes:
    return struct.pack("<II", n, maxbits) + struct.pack(f"<{n}Q", *freqs)


def decode(blob: bytes, n: int):
    rc = struct.unpack_from("<i", blob, 0)[0]
    lens = struct.unpack_from(f"<{n}I", blob, 4) if n else ()
    return rc, lens


def cases():
    rng = random.Random(0x9E11A9)

    # Hand-picked edge cases.
    yield "empty-alphabet", 0, 15, []
    yield "all-zero-288", 288, 15, [0] * 288
    yield "single-symbol", 288, 15, [0] * 287 + [7]
    yield "two-symbols", 32, 15, [5, 0, 3] + [0] * 29
    yield "two-equal", 32, 15, [1, 0, 1] + [0] * 29
    yield "three-minimal", 3, 15, [1, 1, 1]
    yield "equal-8-limit3", 8, 3, [1] * 8
    yield "equal-288", 288, 15, [1] * 288
    yield "equal-288-limit8", 288, 8, [1] * 288
    yield "powers-of-two", 4, 15, [8, 4, 2, 1]
    yield "fibonacci", 6, 4, [1, 1, 2, 3, 5, 8]
    yield "fibonacci-unlimited", 6, 15, [1, 1, 2, 3, 5, 8]
    yield "one-heavy", 19, 7, [1000000] + [1] * 18
    yield "tree-alphabet-19", 19, 7, [3, 4, 0, 0, 60, 100, 0, 3, 40, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0]
    yield "dist-alphabet-30", 30, 15, list(range(1, 31))
    yield "dist-alphabet-32", 32, 15, list(range(1, 33))
    yield "literal-288-ramp", 288, 15, list(range(1, 289))

    # Boundary: exactly 2^maxbits and one more used symbols (alphabet cap 288).
    for maxbits in (1, 2, 3, 7, 8):
        fit = 1 << maxbits
        if fit <= 288:
            yield f"fit-2^{maxbits}", fit, maxbits, [1] * fit
        if fit + 1 <= 288:
            yield f"overflow-2^{maxbits}+1", fit + 1, maxbits, [1] * (fit + 1)

    # Limit reduction: maxbits far above numsymbols - 1.
    for used in (3, 4, 5, 17, 100):
        yield f"reduction-{used}", used, 15, [1] * used
        yield f"reduction-{used}-limit2", used, 2, [1] * used

    # Deterministic pseudo-random vectors across the parameter space.
    for trial in range(4000):
        n = rng.randint(0, 288)
        maxbits = rng.randint(1, 15)
        style = trial % 4
        if style == 0:
            freqs = [rng.choice([0, 0, 1, 2, 3, 5, 8]) for _ in range(n)]
        elif style == 1:
            freqs = [rng.randint(0, 1000000) for _ in range(n)]
        elif style == 2:
            freqs = [0] * n
            for _ in range(rng.randint(0, min(n, 32))):
                freqs[rng.randrange(n)] = rng.randint(1, 10**6)
        else:
            freqs = [1 << rng.randint(0, 20) for _ in range(n)]
        yield f"random-{trial}", n, maxbits, freqs

    # Large weights: realistic block counts and the 2^55 boundary.
    yield "million-weights", 288, 15, [1000000] * 288
    yield "near-boundary-ok", 8, 15, [(1 << 54)] * 8
    yield "boundary-reject-3syms", 3, 15, [1, 1 << 55, 1]
    yield "boundary-reject-mixed", 5, 15, [1, 1 << 55, 1, 1 << 56, 1]
    yield "two-symbols-huge-ok", 2, 15, [1, 1 << 60]


def main() -> None:
    if not NATIVE.exists():
        raise SystemExit("Build the Zig tool first: zig build")
    build_reference()

    checked = 0
    errors = 0
    for label, n, maxbits, freqs in cases():
        payload = encode(n, maxbits, freqs)
        a = subprocess.run([str(NATIVE)], input=payload, capture_output=True)
        b = subprocess.run([str(REF_BIN)], input=payload, capture_output=True)
        if a.returncode or b.returncode:
            raise SystemExit(f"HARNESS {label}: status={a.returncode}/{b.returncode}")
        checked += 1
        if a.stdout != b.stdout:
            errors += 1
            rc_a, lens_a = decode(a.stdout, n)
            rc_b, lens_b = decode(b.stdout, n)
            print(f"MISMATCH {label} (n={n}, maxbits={maxbits}): "
                  f"rc={rc_a}/{rc_b}")
            for i, (x, y) in enumerate(zip(lens_a, lens_b)):
                if x != y:
                    print(f"  symbol {i}: zig={x} c={y} freq={freqs[i]}")
                    break
            if errors >= 10:
                raise SystemExit("too many mismatches, aborting")
    if errors:
        raise SystemExit(f"Katajainen differential: {checked - errors}/{checked} match")
    print(f"Katajainen differential: {checked}/{checked} byte-exact")


if __name__ == "__main__":
    main()
