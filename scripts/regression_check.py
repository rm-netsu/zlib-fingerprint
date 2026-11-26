#!/usr/bin/env python3
"""End-to-end regression check over fixtures-regression/.

For every case in the manifest this asserts that

  1. the golden stream file still matches its recorded SHA-256;
  2. the official release wrapper (binaries/zlib-<ver>, when present)
     reproduces the golden byte for byte — validates the environment;
  3. the native Zig engine (zig-out/bin/zcompress or zzopfli) reproduces
     the golden byte for byte — catches any engine regression;
  4. the zlib-fingerprint search output contains every expected
     substring — catches search-order, header-prediction and
     candidate-generation regressions (e.g. missing strategy/level
     combinations).

Exit code 0 iff every available check passes. Use --skip-official on CI
runners without the reference binaries, --skip-search to check only the
compression engines.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FR = ROOT / "fixtures-regression"


def check(condition, failures, case, what):
    if not condition:
        failures.append(f"{case}: {what}")
    return condition


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-official", action="store_true")
    parser.add_argument("--skip-engine", action="store_true")
    parser.add_argument("--skip-search", action="store_true")
    parser.add_argument("--timeout", type=float, default=300.0)
    args = parser.parse_args()

    manifest = json.loads((FR / "manifest.json").read_text(encoding="utf-8"))
    failures = []
    passed = skipped = 0

    for case in manifest:
        cid = case["id"]
        golden_path = FR / case["golden"]
        payload_path = FR / case["payload"]

        # 1. golden integrity
        if not check(golden_path.exists(), failures, cid, "golden missing"):
            continue
        golden = golden_path.read_bytes()
        digest = hashlib.sha256(golden).hexdigest()
        if not check(digest == case["golden_sha256"], failures, cid,
                     "golden sha256 mismatch"):
            continue
        payload = payload_path.read_bytes()

        # 2. official wrapper reproduction
        producer = case["producer"]
        official = None
        if producer["implementation"] == "zlib" and not args.skip_official:
            official = ROOT / "binaries" / f"zlib-{producer['version']}"
        if official is not None:
            if official.exists():
                proc = subprocess.run(
                    [str(official), *map(str, producer["params"])],
                    input=payload, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, timeout=args.timeout)
                if check(proc.returncode == 0, failures, cid,
                         f"official wrapper rc={proc.returncode}"):
                    check(proc.stdout == golden, failures, cid,
                          "official wrapper output differs from golden")
                    passed += 1
            else:
                skipped += 1

        # 3. native engine reproduction
        if not args.skip_engine:
            engine = case["engine"]
            exe = ROOT / "zig-out" / "bin" / engine["tool"]
            if not check(exe.exists(), failures, cid,
                         f"{engine['tool']} not built (zig build)"):
                continue
            proc = subprocess.run([str(exe), *engine["args"]],
                                  input=payload, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL,
                                  timeout=args.timeout)
            if check(proc.returncode == 0, failures, cid,
                     f"engine rc={proc.returncode}"):
                check(proc.stdout == golden, failures, cid,
                      "native engine output differs from golden")
                passed += 1

        # 4. search identification
        expects = case.get("search_expects")
        if expects and not args.skip_search:
            fp = ROOT / "zig-out" / "bin" / "zlib-fingerprint"
            if not check(fp.exists(), failures, cid,
                         "zlib-fingerprint not built (zig build)"):
                continue
            proc = subprocess.run([str(fp), str(golden_path)],
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL,
                                  timeout=args.timeout)
            out = proc.stdout.decode("utf-8", "replace")
            for expect in expects:
                check(expect in out, failures, cid,
                      f"search output missing {expect!r}")
            passed += 1

    print(f"{len(manifest)} cases: {passed} checks passed, "
          f"{skipped} official-wrapper checks skipped (binary absent)")
    if failures:
        print("FAILURES:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("All regression checks passed.")


if __name__ == "__main__":
    main()
