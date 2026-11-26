#!/usr/bin/env python3
"""Zopfli release-matrix extension: iterations beyond the baseline set and
a >20 MiB mixed corpus (BACKLOG item).

Extends version_matrix.py in two directions:

  1. iteration counts {4, 6, 7, 8, 9, 12, 20, 30, 60, 100} — outside the
     baseline {1, 2, 3, 5, 10, 15, 50} — on a deterministic 6-input
     subset of the standard corpus, comparing the four official release
     CLIs with each other and with the native Zig variants;
  2. a 24 MiB mixed input (runs + text + random regions) at iterations
     1 and 2 for every release, CLI vs native byte-exact, with
     round-trip decompression of every stream.

Every finished case is appended to zopfli-matrix-ext-journal.jsonl, so the
long big-corpus phase can resume across invocations; --report assembles
zopfli-matrix-ext.json from the journal.

Usage:
  python3 scripts/zopfli_matrix_ext.py sweep     # small inputs, new iters
  python3 scripts/zopfli_matrix_ext.py big --releases 1.0.0,1.0.1
  python3 scripts/zopfli_matrix_ext.py big --releases 1.0.2,1.0.3
  python3 scripts/zopfli_matrix_ext.py report
"""
import argparse
import hashlib
import json
import pathlib
import random
import subprocess
import sys
import time
import urllib.request
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
NATIVE = ROOT / "zig-out" / "bin" / "zzopfli"
REF_DIR = ROOT / "outputs" / "zopfli-references"
JOURNAL = ROOT / "zopfli-matrix-ext-journal.jsonl"
REPORT = ROOT / "zopfli-matrix-ext.json"

TAGS = {
    "1.0.0": "zopfli-1.0.0",
    "1.0.1": "zopfli-1.0.1",
    "1.0.2": "zopfli-1.0.2",
    "1.0.3": "zopfli-1.0.3",
}
BASELINE_ITERATIONS = {1, 2, 3, 5, 10, 15, 50}


def ensure_reference(version):
    """Build the official zopfli CLI from the tagged sources."""
    exe = REF_DIR / f"built-{version}" / f"zopfli-{version}"
    if exe.exists():
        return exe
    REF_DIR.mkdir(parents=True, exist_ok=True)
    tar = REF_DIR / f"zopfli-{version}.tar.gz"
    if not tar.exists():
        url = ("https://codeload.github.com/google/zopfli/tar.gz/"
               f"refs/tags/{TAGS[version]}")
        print(f"  downloading {tar.name} ...", flush=True)
        urllib.request.urlretrieve(url, tar)
    builddir = REF_DIR / f"built-{version}"
    src = REF_DIR / f"zopfli-zopfli-{version}"
    if not src.exists():
        subprocess.run(["tar", "xzf", str(tar)], cwd=REF_DIR, check=True)
    builddir.mkdir(exist_ok=True)
    # 1.0.0/1.0.1 ship a lowercase makefile whose default target builds
    # ./zopfli directly; 1.0.2+ have a Makefile with a zopfli target.
    if (src / "Makefile").exists():
        target = ["zopfli"]
    else:
        target = []
    r = subprocess.run(["make", "-C", str(src), *target],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True)
    if r.returncode != 0:
        sys.exit(f"reference build failed for {version}:\n{r.stdout[-1500:]}")
    subprocess.run(["cp", str(src / "zopfli"), str(exe)], check=True)
    return exe


def corpus_sweep():
    """Deterministic subset of the version-matrix corpus generators."""
    rng = random.Random(0x5EED5)
    items = {
        "one-byte": b"a",
        "repeat-a-4096": b"A" * 4096,
        "periodic-4096": (b"abc12345" * 512)[:4096],
        "dict-reuse-48k": None,
        "mixed-runs-64k": None,
        "alphabet-256x128": bytes(range(256)) * 128,
    }
    chunks = [rng.randbytes(256) for _ in range(64)]
    items["dict-reuse-48k"] = b"".join(chunks[i % 17] for i in range(192))
    motif = (rng.randbytes(64) + b"A" * 64 +
             b"The quick brown fox. " * 16 + rng.randbytes(64))
    items["mixed-runs-64k"] = (motif * 32)[:65536]
    return items


def corpus_big():
    """A >20 MiB mixed corpus: long runs, text, random and periodic regions."""
    rng = random.Random(0xB16B00B5)
    parts = []
    while sum(map(len, parts)) < 24 * 1024 * 1024:
        r = rng.random()
        if r < 0.25:
            parts.append(bytes([rng.randrange(256)]) * 65536)
        elif r < 0.55:
            parts.append((b"the quick brown fox jumps over the lazy dog. "
                          * 2048)[:65536])
        elif r < 0.8:
            parts.append(rng.randbytes(65536))
        else:
            parts.append((b"abc12345" * 8192)[:65536])
    return b"".join(parts)[:24 * 1024 * 1024]


def run_cli(exe, data, iters):
    """The CLI needs a filename argument in every release (-c = stdout)."""
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".bin") as f:
        f.write(data)
        f.flush()
        p = subprocess.run([str(exe), "--zlib", "-c", f"--i{iters}", f.name],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=1800)
    return p.returncode, p.stdout


def run_native(data, iters, release):
    p = subprocess.run([str(NATIVE), str(iters), release], input=data,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       timeout=1800)
    return p.returncode, p.stdout


def record_case(kind, name, iters, results):
    """results: {producer: [rc, len, sha256]} + verification info."""
    rec = {"kind": kind, "input": name, "iterations": iters,
           "results": results}
    with JOURNAL.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")


def compare_and_record(kind, name, iters, data, runs):
    """runs: {producer: (rc, output)}; verify, journal and report."""
    results = {}
    for producer, (rc, out) in runs.items():
        entry = [rc, len(out), hashlib.sha256(out).hexdigest()]
        if rc == 0 and out:
            try:
                entry.append(zlib.decompress(out) == data)
            except zlib.error as ex:
                entry.append(f"roundtrip failed: {ex}")
        else:
            entry.append(None)
        results[producer] = entry
    record_case(kind, name, iters, results)
    ok = all(v[0] == 0 for v in runs.values())
    identical = len({v[2] for v in results.values() if v[0] == 0}) <= 1
    print(f"  {kind}/{name}@{iters}: "
          f"{'identical' if identical else 'DIFFER'} "
          f"({', '.join(f'{p}:{v[1]}B' for p, v in results.items())})",
          flush=True)
    return ok, identical


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sweep")
    p2 = sub.add_parser("big")
    p2.add_argument("--releases", default="1.0.0,1.0.1,1.0.2,1.0.3")
    p2.add_argument("--iterations", default="1,2")
    sub.add_parser("report")
    args = parser.parse_args()

    if args.cmd == "report":
        assemble_report()
        return

    refs = {v: ensure_reference(v) for v in TAGS}
    started = time.monotonic()

    if args.cmd == "sweep":
        done = set()
        if JOURNAL.exists():
            for line in JOURNAL.read_text().splitlines():
                if line.strip():
                    rec = json.loads(line)
                    done.add((rec["kind"], rec["input"], rec["iterations"]))
        iterations = [i for i in (4, 6, 7, 8, 9, 12, 20, 30, 60, 100)
                      if i not in BASELINE_ITERATIONS]
        corpus = corpus_sweep()
        fresh = 0
        for name, data in corpus.items():
            for iters in iterations:
                if ("sweep", name, iters) in done:
                    continue
                runs = {}
                for v, exe in refs.items():
                    runs[f"cli-{v}"] = run_cli(exe, data, iters)
                    runs[f"native-{v}"] = run_native(data, iters, v)
                compare_and_record("sweep", name, iters, data, runs)
                fresh += 1
            print(f"[sweep] {name} done ({fresh} fresh), "
                  f"{time.monotonic()-started:.0f}s", flush=True)
    else:
        releases = args.releases.split(",")
        iterations = [int(x) for x in args.iterations.split(",")]
        data = corpus_big()
        print(f"[big] corpus: {len(data)} bytes", flush=True)
        for iters in iterations:
            for v in releases:
                exe = refs[v]
                t0 = time.monotonic()
                runs = {f"cli-{v}": run_cli(exe, data, iters),
                        f"native-{v}": run_native(data, iters, v)}
                compare_and_record("big", "mixed-24mib", iters, data, runs)
                print(f"[big] {v}@{iters}: "
                      f"{time.monotonic()-t0:.0f}s", flush=True)


def assemble_report():
    cases = []
    if not JOURNAL.exists():
        sys.exit("no journal; run sweep/big first")
    for line in JOURNAL.read_text().splitlines():
        if line.strip():
            cases.append(json.loads(line))
    sweep = [c for c in cases if c["kind"] == "sweep"]
    big = [c for c in cases if c["kind"] == "big"]
    # group producers by identical result vector over the sweep
    vectors = {}
    for c in sweep:
        for producer, res in c["results"].items():
            vectors.setdefault(producer, []).append(res[2])
    groups = {}
    for producer, vec in vectors.items():
        groups.setdefault(tuple(vec), []).append(producer)
    native_vs_cli = 0
    checked = 0
    for c in cases:
        for v in TAGS:
            cli, nat = f"cli-{v}", f"native-{v}"
            if cli in c["results"] and nat in c["results"]:
                a, b = c["results"][cli], c["results"][nat]
                if a[0] == 0 and b[0] == 0:
                    checked += 1
                    if a[2] != b[2]:
                        native_vs_cli += 1
    report = {
        "tool": "scripts/zopfli_matrix_ext.py",
        "date": time.strftime("%Y-%m-%d"),
        "sweep_iterations": sorted({c["iterations"] for c in sweep}),
        "sweep_inputs": sorted({c["input"] for c in sweep}),
        "big_corpus_bytes": 24 * 1024 * 1024,
        "big_cases": len(big),
        "case_count": len(cases),
        "sweep_producer_groups": [sorted(m) for m in groups.values()],
        "native_vs_cli_checked": checked,
        "native_vs_cli_mismatches": native_vs_cli,
        "roundtrip_failures": [
            {"kind": c["kind"], "input": c["input"],
             "iterations": c["iterations"], "producer": p}
            for c in cases for p, res in c["results"].items()
            if res[3] is not True],
        "cases": cases,
        "note": "Iteration values outside the baseline set and a >20 MiB "
                "mixed corpus; CLI vs native byte-exactness per release.",
    }
    REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"{len(cases)} cases ({len(sweep)} sweep, {len(big)} big) -> "
          f"{REPORT}")
    print(f"native vs cli mismatches: {native_vs_cli}")
    print(f"round-trip failures: {len(report['roundtrip_failures'])}")


if __name__ == "__main__":
    main()
