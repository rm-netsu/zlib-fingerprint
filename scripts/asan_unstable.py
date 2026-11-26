#!/usr/bin/env python3
"""Run the documented unstable historical-zlib paths under ASan/UBSan.

The fingerprint search deliberately excludes several code paths of the
original C releases because their behaviour is undefined or crashes the
original library (see README.md, "Known divergence from real zlib"):

  1. class A (1.0.1-1.0.5) level 0 with memLevel < 8: deflate_stored has no
     pending-size cap and overruns the pending buffer;
  2. zlib 1.2.4-1.2.8 level 0 with strategy Z_HUFFMAN_ONLY/Z_RLE:
     _tr_flush_block's stored fallback writes far beyond the pending buffer;
  3. windowBits 8 at level >= 1 for classes A/B (1.0.1-1.0.9): the wrapped
     MAX_DIST leads to out-of-bounds reads in the match finder;
  4. class C (1.1.0-1.2.0) windowBits 8: rejected at init (control case).

This harness rebuilds selected original releases with
`-fsanitize=address,undefined -fno-sanitize-recover=all`, runs the unstable
parameter combinations plus clean control cases, and records what the
sanitizers actually report. The results validate the exclusions documented
in README.md / EQUIVALENCE.md. Output: asan-results.json.
"""
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request

RELEASES = {
    # version: (tarball url, class)
    "1.0.5": ("https://zlib.net/fossils/zlib-1.0.5.tar.gz", "A"),
    "1.0.9": ("https://zlib.net/fossils/zlib-1.0.9.tar.gz", "B"),
    "1.2.0": ("https://github.com/madler/zlib/archive/refs/tags/v1.2.0.tar.gz", "C"),
    "1.2.2": ("https://github.com/madler/zlib/archive/refs/tags/v1.2.2.tar.gz", "D"),
    "1.2.4": ("https://github.com/madler/zlib/archive/refs/tags/v1.2.4.tar.gz", "F"),
    "1.2.8": ("https://github.com/madler/zlib/archive/refs/tags/v1.2.8.tar.gz", "F"),
    "1.2.9": ("https://github.com/madler/zlib/archive/refs/tags/v1.2.9.tar.gz", "G"),
    "1.2.11": ("https://github.com/madler/zlib/archive/refs/tags/v1.2.11.tar.gz", "H"),
}

SAN_FLAGS = ["-fsanitize=address,undefined", "-fno-sanitize-recover=all",
             "-fno-omit-frame-pointer", "-g", "-O1"]


def sh(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)


def build(version, url, workdir):
    """Build zlib <version> + the wrappers with sanitizers.

    The historical configure scripts only honor CC/CFLAGS from the
    ENVIRONMENT (passing them as arguments is silently ignored, which once
    produced unsanitized libraries), so both are exported explicitly.
    """
    vdir = workdir / f"zlib-{version}"
    env = dict(os.environ)
    env["CC"] = "gcc"
    env["CFLAGS"] = " ".join(SAN_FLAGS)
    mk_path = vdir / "Makefile"
    sanitized = (mk_path.exists()
                 and "fsanitize" in mk_path.read_text()
                 and (vdir / "libz.a").exists())
    if not sanitized:
        tar = workdir / f"zlib-{version}.tar.gz"
        if not tar.exists():
            print(f"  downloading {tar.name} ...", flush=True)
            urllib.request.urlretrieve(url, tar)
        subprocess.run(["rm", "-rf", str(vdir)], check=True)
        subprocess.run(["tar", "xzf", str(tar)], cwd=workdir, check=True)
        r = subprocess.run(["./configure", "--static"], cwd=vdir, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True)
        if r.returncode != 0:
            return None, r.stdout[-2000:]
        mk = (vdir / "Makefile").read_text()
        if "fsanitize" not in mk:
            return None, ("configure dropped the sanitizer flags:\n"
                          + mk[:400])
        r = subprocess.run(["make", "libz.a"], cwd=vdir, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True)
        if r.returncode != 0:
            return None, r.stdout[-2000:]
    exe = workdir / f"zsan-{version}"
    r = sh(["gcc", *SAN_FLAGS, str(pathlib.Path(__file__).resolve().parent.parent
                                   / "binaries" / "zlib_wrapper.c"),
            "-I.", "-L.", "-lz", "-o", str(exe)], cwd=vdir)
    if r.returncode != 0:
        return None, r.stdout[-2000:]
    # Streaming wrapper (for the deflateParams crash reproduction).
    zsexe = workdir / f"zsanstream-{version}"
    r = sh(["gcc", *SAN_FLAGS, str(pathlib.Path(__file__).resolve().parent.parent
                                   / "binaries" / "zstream_wrapper.c"),
            "-I.", "-L.", "-lz", "-o", str(zsexe)], cwd=vdir)
    if r.returncode != 0:
        return None, r.stdout[-2000:]
    return (exe, zsexe), None


def payload():
    return (b"The quick brown fox jumps over the lazy dog. " * 4096)[:131072]


def summarize(stderr):
    lines = [ln for ln in stderr.splitlines()
             if ("ERROR:" in ln or "runtime error:" in ln
                 or "SUMMARY:" in ln)]
    return " | ".join(lines[:4])[:400]


def main():
    workdir = pathlib.Path(__file__).resolve().parent.parent / "asan-work"
    workdir.mkdir(exist_ok=True)
    data = payload()
    cases = []
    # (label, version, level, memLevel, strategy, windowBits, expectation)
    for mem in (1, 4, 7):
        cases.append((f"A level0 mem{mem}", "1.0.5", 0, mem, 0, 15,
                      "pending-buffer overrun of class A deflate_stored"))
    for strat in (2, 3):
        cases.append((f"F level0 strat{strat}", "1.2.4", 0, 8, strat, 15,
                      "pending-buffer overrun in _tr_flush_block"))
        cases.append((f"F-late level0 strat{strat}", "1.2.8", 0, 8, strat, 15,
                      "same code path in 1.2.8"))
    for ver, cls in (("1.0.5", "A"), ("1.0.9", "B")):
        for lvl in (1, 6):
            cases.append((f"{cls} wbits8 level{lvl}", ver, lvl, 8, 0, 8,
                          "wrapped MAX_DIST out-of-bounds reads"))
    cases.append(("C wbits8 level1 (rejected)", "1.2.0", 1, 8, 0, 8,
                  "windowBits 8 rejected at init (control)"))
    cases.append(("D wbits8 level1 (rejected)", "1.2.2", 1, 8, 0, 8,
                  "windowBits 8 rejected at init (control)"))
    # clean controls: must pass under sanitizers
    for ver in ("1.0.5", "1.0.9", "1.2.0", "1.2.2", "1.2.4", "1.2.8",
                "1.2.9", "1.2.11"):
        cases.append((f"control level6", ver, 6, 8, 0, 15,
                      "clean path control (must not report)"))
    cases.append(("control level0", "1.2.11", 0, 8, 0, 15,
                  "clean stored path control (must not report)"))
    cases.append(("control level0 mem1", "1.0.9", 0, 1, 0, 15,
                  "class B stored with small memLevel (must not report)"))

    # Mid-stream deflateParams to level 0 with small memLevel: the stream
    # matrix caught glibc heap-corruption aborts (SIGABRT) on 1.0.1-1.0.5.
    param_cases = [
        ("A params 9->0 mem1", "1.0.5", ["params", "9", "1", "0", "15",
                                          "0", "0", "65536", "0", "0"],
         "deflateParams(level 0) mid-stream crashes class A with memLevel 1"),
        ("A params 9->0 mem8", "1.0.5", ["params", "9", "8", "0", "15",
                                          "0", "0", "65536", "0", "0"],
         "same switch at memLevel 8"),
        ("B params 9->0 mem1 control", "1.0.9", ["params", "9", "1", "0",
                                                   "15", "0", "0", "65536",
                                                   "0", "0"],
         "class B survives the same switch (must not report)"),
    ]

    binaries = {}
    results = []
    started = time.monotonic()
    for version, (url, cls) in RELEASES.items():
        print(f"[build] zlib {version} (class {cls}) ...", flush=True)
        exes, err = build(version, url, workdir)
        if exes is None:
            print(f"  BUILD FAILED:\n{err}", flush=True)
            sys.exit(1)
        binaries[version] = exes

    for label, version, level, mem, strat, wb, expectation in cases:
        exe = binaries[version][0]
        try:
            proc = subprocess.run([str(exe), str(level), str(mem), str(strat),
                                   str(wb)], input=data,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=60)
            rc, out, err = proc.returncode, proc.stdout, proc.stderr.decode(
                "utf-8", "replace")
        except subprocess.TimeoutExpired:
            rc, out, err = 124, b"", "timeout"
        record = {
            "case": label, "version": version,
            "params": [level, mem, strat, wb], "expectation": expectation,
            "exit": rc, "output_len": len(out),
            "sanitizer": summarize(err),
        }
        results.append(record)
        verdict = "SANITIZER HIT" if record["sanitizer"] else (
            "timeout" if rc == 124 else "clean")
        print(f"  {label:28s} v{version:6s} exit={rc:4d} len={len(out):6d} "
              f"{verdict}", flush=True)

    # streaming deflateParams crash cases via the sanitized zstream wrapper
    for label, version, args, expectation in param_cases:
        exe = binaries[version][1]
        try:
            proc = subprocess.run([str(exe), *args], input=data,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=60)
            rc, out, err = proc.returncode, proc.stdout, proc.stderr.decode(
                "utf-8", "replace")
        except subprocess.TimeoutExpired:
            rc, out, err = 124, b"", "timeout"
        record = {
            "case": label, "version": version, "args": args,
            "expectation": expectation, "exit": rc,
            "output_len": len(out), "sanitizer": summarize(err),
        }
        results.append(record)
        verdict = "SANITIZER HIT" if record["sanitizer"] else (
            "timeout" if rc == 124 else "clean")
        print(f"  {label:28s} v{version:6s} exit={rc:4d} len={len(out):6d} "
              f"{verdict}", flush=True)

    report = {
        "tool": "scripts/asan_unstable.py",
        "date": time.strftime("%Y-%m-%d"),
        "flags": SAN_FLAGS,
        "payload": "131072 bytes of repeated English sentence",
        "results": results,
        "elapsed_seconds": round(time.monotonic() - started, 1),
    }
    out = pathlib.Path(__file__).resolve().parent.parent / "asan-results.json"
    out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    hits = sum(1 for r in results if r["sanitizer"])
    print(f"\n{len(results)} cases, {hits} sanitizer hits -> {out.name}",
          flush=True)


if __name__ == "__main__":
    main()
