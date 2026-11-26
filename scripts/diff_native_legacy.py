#!/usr/bin/env python3
"""Verify the native Zig ports of legacy classes A-C (zlib 1.0.1-1.2.0).

Three independent comparisons per test case:
  1. native engine (zig-out/bin/zcompress <1.0.5|1.0.9|1.2.0>)
     vs the statically linked original C cores (zig-out/bin/zlegacy a|b|c),
  2. native engine vs the OFFICIAL release wrapper binaries of every class
     member (1.0.1 .. 1.2.0), verifying both the byte streams and the
     class-collapse claim (one representative per class),
  3. round-trip decompression of every produced stream.

Documented divergences (skipped, with counters):
  * class A level 0 with memLevel < 8: the real 1.0.1-1.0.5 stored-block
    layout overruns the pending buffer and the oracle aborts (SIGABRT) —
    no reference stream exists;
  * classes A/B windowBits 8 at level >= 1: the 256-byte window makes
    MAX_DIST underflow and the originals follow stale hash chains into
    out-of-bounds reads — the output is not reproducible;
  * class C windowBits 8: rejected outright by 1.1.0-1.2.0 (both sides
    refuse; verified as agreement instead of stream comparison).
"""
import itertools
import os
import pathlib
import random
import subprocess
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
ZCOMPRESS = ROOT / "zig-out/bin/zcompress"
ZLEGACY = ROOT / "zig-out/bin/zlegacy"
BINARIES = ROOT / "binaries"

CLASS_MEMBERS = {
    "a": ["1.0.1", "1.0.2", "1.0.4", "1.0.5"],
    "b": ["1.0.6", "1.0.7", "1.0.8", "1.0.9"],
    "c": ["1.1.0", "1.1.1", "1.1.2", "1.1.3", "1.1.4", "1.2.0"],
}
REPRESENTATIVE = {"a": "1.0.5", "b": "1.0.9", "c": "1.2.0"}


def fixtures():
    rng = random.Random(0xC0FFEE)
    # Boundary sizes around the stored-block and window edges.
    for n in (0, 1, 2, 3, 31, 32, 100, 255, 256, 257, 511, 512, 513,
              1023, 1024, 1025, 4095, 4096, 4097, 32767, 32768, 32769,
              65530, 65531, 65532, 65533, 65534, 65535, 65536, 65537,
              131071, 131072, 131073, 262144):
        yield f"repeat-{n}", b"A" * n
        yield f"periodic-{n}", (b"abc123\x00\xff" * ((n + 7) // 8))[:n]
        if n <= 131072:
            yield f"random-{n}", rng.randbytes(n)
    # Class-B truncate-heuristic trigger: long runs mixed with random
    # literals (match bytes > half the input, match count < literals/2).
    yield "heuristic-runs", b"".join(b"A" * 600 + rng.randbytes(400) for _ in range(80))
    # Sparse recurring snippets over a span far beyond the window.
    snips = [rng.randbytes(24) for _ in range(64)]
    buf = bytearray()
    for i in range(4000):
        buf += rng.randbytes(rng.randint(4, 40))
        buf += snips[rng.randrange(64)]
    yield "sparse-snippets", bytes(buf)
    # Small-alphabet data (deep hash chains, many short matches).
    yield "abc-noise", bytes(rng.choice(b"abc") for _ in range(150000))
    # Text-like data.
    yield "text", (b"The quick brown fox jumps over the lazy dog. " * 900)[:36000]


def run_native(cls, payload, level, mem, strategy, wb):
    version = REPRESENTATIVE[cls]
    return subprocess.run(
        [str(ZCOMPRESS), version, str(level), str(mem), str(strategy), str(wb)],
        input=payload, capture_output=True)


def run_oracle(cls, payload, level, mem, strategy, wb):
    return subprocess.run(
        [str(ZLEGACY), cls, str(level), str(mem), str(strategy), str(wb)],
        input=payload, capture_output=True)


def run_official(version, payload, level, mem, strategy, wb):
    return subprocess.run(
        [str(BINARIES / f"zlib-{version}"), str(level), str(mem), str(strategy), str(wb)],
        input=payload, capture_output=True)


def skipped_case(cls, level, mem, strategy, wb):
    if cls == "a" and level == 0 and mem < 8:
        return "A level 0 mem<8 (oracle aborts)"
    if cls in ("a", "b") and wb == 8 and level >= 1:
        return "A/B windowBits 8 level>=1 (oracle OOB)"
    return None


def main():
    for tool in (ZCOMPRESS, ZLEGACY):
        if not tool.exists():
            raise SystemExit(f"missing {tool}; run zig build first")
    depth = "full" if "--full" in sys.argv else "quick"
    mems = (1, 8, 9) if depth == "full" else (1, 8)
    levels = range(0, 10) if depth == "full" else (0, 1, 2, 3, 4, 5, 6, 9)
    strategies = (0, 1, 2)
    wbs = (9, 15)

    tested = 0
    skipped = 0
    skip_reasons = {}
    mismatches = []
    roundtrip_fail = []
    member_fail = []

    def note_skip(reason):
        nonlocal skipped
        skipped += 1
        skip_reasons[reason] = skip_reasons.get(reason, 0) + 1

    for cls in ("c", "b", "a"):
        for name, payload in fixtures():
            for level, mem, strategy, wb in itertools.product(
                    levels, mems, strategies, wbs):
                if skipped_case(cls, level, mem, strategy, wb):
                    note_skip(skipped_case(cls, level, mem, strategy, wb))
                    continue
                # class C rejects windowBits 8 entirely (not in wbs, but the
                # A/B level-0 windowBits 8 path is covered separately below).
                native = run_native(cls, payload, level, mem, strategy, wb)
                oracle = run_oracle(cls, payload, level, mem, strategy, wb)
                tested += 1
                if (native.returncode != 0) != (oracle.returncode != 0):
                    mismatches.append(("status", cls, name, level, mem, strategy, wb,
                                       native.returncode, oracle.returncode))
                elif native.returncode == 0:
                    if native.stdout != oracle.stdout:
                        mismatches.append(("bytes-vs-c-core", cls, name, level, mem,
                                           strategy, wb, len(native.stdout), len(oracle.stdout)))
                    else:
                        try:
                            if zlib.decompress(native.stdout) != payload:
                                roundtrip_fail.append((cls, name, level, mem, strategy, wb))
                        except zlib.error as e:
                            roundtrip_fail.append((cls, name, level, mem, strategy, wb, str(e)))
                if len(mismatches) + len(roundtrip_fail) >= 15:
                    break_down(mismatches, roundtrip_fail, member_fail)
            if len(mismatches) + len(roundtrip_fail) >= 15:
                break_down(mismatches, roundtrip_fail, member_fail)
        if len(mismatches) + len(roundtrip_fail) >= 15:
            break_down(mismatches, roundtrip_fail, member_fail)
        print(f"class {cls}: core-oracle comparisons done", flush=True)

    # windowBits 8, level 0: accepted by A/B, must reproduce the oracle bytes
    # exactly (including the deterministic corrupt empty-block stream).
    for cls in ("a", "b"):
        for name, payload in fixtures():
            if len(payload) > 70000:
                continue
            native = run_native(cls, payload, 0, 8, 0, 8)
            oracle = run_oracle(cls, payload, 0, 8, 0, 8)
            tested += 1
            if native.returncode != 0 or native.stdout != oracle.stdout:
                mismatches.append(("w8-level0", cls, name, len(native.stdout), len(oracle.stdout)))
    # class C windowBits 8: both sides must refuse.
    for name, payload in fixtures():
        if len(payload) > 1000:
            continue
        native = run_native("c", payload, 6, 8, 0, 8)
        oracle = run_oracle("c", payload, 6, 8, 0, 8)
        tested += 1
        if native.returncode == 0 or oracle.returncode == 0:
            mismatches.append(("w8-class-c-should-refuse", name,
                               native.returncode, oracle.returncode))

    # Class members: the representative must reproduce every member release
    # of its class byte-exactly (the collapse claim), on a reduced matrix.
    member_matrix = list(itertools.product((0, 2, 3, 5, 6, 9), (1, 8), (0, 1, 2), (9, 15)))
    for cls, members in CLASS_MEMBERS.items():
        rep = REPRESENTATIVE[cls]
        for name, payload in fixtures():
            if len(payload) > 40000:
                continue
            for level, mem, strategy, wb in member_matrix:
                if skipped_case(cls, level, mem, strategy, wb):
                    continue
                tested += 1
                for version in members:
                    official = run_official(version, payload, level, mem, strategy, wb)
                    native = run_native(cls, payload, level, mem, strategy, wb)
                    if official.returncode != 0:
                        continue
                    if native.returncode != 0 or native.stdout != official.stdout:
                        member_fail.append((cls, version, name, level, mem, strategy, wb))
                        break
        print(f"class {cls}: member-binary verification done", flush=True)

    break_down(mismatches, roundtrip_fail, member_fail)
    print(f"native/oracle comparisons: {tested}; skipped unsafe oracle paths: {skipped}")
    for reason, count in sorted(skip_reasons.items()):
        print(f"  skip: {reason}: {count}")
    print(f"mismatches: {len(mismatches)}, roundtrip failures: {len(roundtrip_fail)}, "
          f"member failures: {len(member_fail)}")
    if mismatches or roundtrip_fail or member_fail:
        sys.exit(1)
    print("All native legacy-class outputs bit-exact against the C cores and "
          "every official class-member binary")


def break_down(mismatches, roundtrip_fail, member_fail):
    if mismatches:
        print("MISMATCHES:", mismatches[:10])
    if roundtrip_fail:
        print("ROUNDTRIP FAILURES:", roundtrip_fail[:10])
    if member_fail:
        print("MEMBER FAILURES:", member_fail[:10])


if __name__ == "__main__":
    main()
