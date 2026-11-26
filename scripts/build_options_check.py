#!/usr/bin/env python3
"""Build-option output equivalence check (BACKLOG item).

Compiles selected historical releases from their vendor sources with
different build options and asserts that the compressed output is
byte-identical to the default (-O3) build:

  * -O0 / -O3 optimization levels,
  * -DUNALIGNED_OK (unaligned window reads; affects speed only),
  * -DDEBUG (zlib's internal asserts; also switches _tr_tally from the
    inline macros back to the trees.c function),

and documents the one option that DOES change the output:

  * -DFASTEST (exists since 1.1.0): forces level 1 and drops hash-chain
    walking, so its streams differ from every default build — recorded,
    not asserted equal.

Output: build-options-results.json.
"""
import json
import os
import pathlib
import random
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "binaries" / "vendor"
WORK = ROOT / "build-options-work"

VERSIONS = ["1.1.4", "1.2.3", "1.2.11"]
VARIANTS = [
    ("O0", ["-O0"]),
    ("O3", ["-O3"]),
    ("unaligned", ["-O3", "-DUNALIGNED_OK"]),
    ("debug", ["-O2", "-DDEBUG"]),
    ("fastest", ["-O3", "-DFASTEST"]),
]


def sh(cmd, cwd=None, env=None):
    return subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)


def build(version, name, cflags):
    """Compile the whole zlib of <version> plus the wrapper with cflags."""
    out = WORK / f"zbo-{version}-{name}"
    if out.exists():
        return out
    src = VENDOR / f"zlib-{version}"
    if not src.exists():
        sys.exit(f"missing vendor sources for {version}")
    WORK.mkdir(exist_ok=True)
    env = dict(os.environ)
    env["CC"] = "gcc"
    env["CFLAGS"] = " ".join(cflags)
    bdir = WORK / f"build-{version}-{name}"
    if not bdir.exists():
        subprocess.run(["cp", "-r", str(src), str(bdir)], check=True)
        r = sh(["./configure", "--static"], cwd=bdir, env=env)
        if r.returncode != 0:
            sys.exit(f"configure failed {version}/{name}:\n{r.stdout[-1000:]}")
        r = sh(["make", "libz.a"], cwd=bdir, env=env)
        if r.returncode != 0:
            sys.exit(f"make failed {version}/{name}:\n{r.stdout[-1000:]}")
    r = sh(["gcc", "-O2", *cflags,
            str(ROOT / "binaries" / "zlib_wrapper.c"),
            "-I.", "-L.", "-lz", "-o", str(out)], cwd=bdir)
    if r.returncode != 0:
        sys.exit(f"wrapper link failed {version}/{name}:\n{r.stdout[-1000:]}")
    return out


def main():
    rng = random.Random(0x0F17)
    text = (b"the quick brown fox jumps over the lazy dog. " * 128)
    fixtures = {
        "text-4096": text[:4096],
        "random-2000": rng.randbytes(2000),
        "mixed-65536": bytes(
            (i * 31 + (i // 97)) % 256 for i in range(65536)),
    }
    params = [(6, 8, 0, 15), (1, 1, 3, 15), (0, 8, 0, 15), (9, 4, 1, 9)]

    started = time.monotonic()
    results = []
    mismatches = []
    for version in VERSIONS:
        reference = ROOT / "binaries" / f"zlib-{version}"
        for name, cflags in VARIANTS:
            exe = build(version, name, cflags)
            for fix, data in fixtures.items():
                for p in params:
                    runs = {}
                    for tool, path in (("ref", reference), (name, exe)):
                        if not path.exists():
                            sys.exit(f"missing binary {path}")
                        proc = subprocess.run(
                            [str(path), *map(str, p)], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                        runs[tool] = (proc.returncode, proc.stdout)
                    same = runs["ref"] == runs[name]
                    results.append({
                        "version": version, "variant": name,
                        "fixture": fix, "params": list(p),
                        "identical_to_reference": same,
                        "lengths": [len(runs["ref"][1]), len(runs[name][1])],
                    })
                    if not same:
                        mismatches.append(results[-1])
            print(f"  {version}/{name}: "
                  f"{'OK' if not any(m['version'] == version and m['variant'] == name for m in mismatches) else 'DIFFERS'}",
                  flush=True)

    expected_fastest = [m for m in mismatches if m["variant"] == "fastest"]
    unexpected = [m for m in mismatches if m["variant"] != "fastest"]
    report = {
        "tool": "scripts/build_options_check.py",
        "date": time.strftime("%Y-%m-%d"),
        "versions": VERSIONS,
        "variants": {name: flags for name, flags in VARIANTS},
        "case_count": len(results),
        "elapsed_seconds": round(time.monotonic() - started, 1),
        "unexpected_mismatches": unexpected,
        "fastest_mismatches": len(expected_fastest),
        "note": "-O0/-O3/UNALIGNED_OK/DEBUG must be byte-identical to the "
                "default build; FASTEST (since 1.1.0) legitimately changes "
                "the output (forces level 1, no hash chains). x86-64 only; "
                "ARM64 cross-runs were not executed in this environment.",
    }
    out = ROOT / "build-options-results.json"
    out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"{len(results)} cases -> {out}")
    print(f"unexpected mismatches: {len(unexpected)}, "
          f"FASTEST differences: {len(expected_fastest)}")
    if unexpected:
        sys.exit(1)


if __name__ == "__main__":
    main()
