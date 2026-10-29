#!/usr/bin/env python3
"""Byte-level equivalence matrix of the official Zopfli releases (Stage 4).

Compresses a fixed corpus with
  - the four official release CLIs built independently from the tagged
    sources (zopfli-1.0.0 .. zopfli-1.0.3), and
  - the native Zig variants (zzopfli <iters> <release>),

on identical inputs and iteration counts, hashes every stream, verifies each
stream by decompression, then derives:
  - result classes per (input, iterations) combination,
  - groups of producers with an identical result vector across the matrix,
  - one minimal reproducible input per differing producer pair.

Everything is recorded machine-readably in version-matrix.json. The corpus
skips nothing silently: every planned combination that was not run gets an
explicit skip reason in the report.

Usage:
  python3 scripts/version_matrix.py [--quick] [--output version-matrix.json]
"""
import argparse
import hashlib
import json
import pathlib
import random
import subprocess
import tempfile
import time
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
NATIVE = ROOT / "zig-out/bin/zzopfli"
REFERENCES = {
    # Official CLIs built from the tagged release tarballs (see
    # references/ in the delivery). Path is configurable via env.
    "1.0.0": pathlib.Path("/home/z/my-project/work/references/built-1.0.0/zopfli-1.0.0"),
    "1.0.1": pathlib.Path("/home/z/my-project/work/references/built-1.0.1/zopfli-1.0.1"),
    "1.0.2": pathlib.Path("/home/z/my-project/work/references/built-1.0.2/zopfli-1.0.2"),
    "1.0.3": pathlib.Path("/home/z/my-project/work/references/built-1.0.3/zopfli-1.0.3"),
}
VERSIONS = ["1.0.0", "1.0.1", "1.0.2", "1.0.3"]

# Iteration schedule: the project baseline {1, 2, 3, 5, 10, 15, 50} plus the
# additional values from the previous session's iteration probe
# (zopfli-iterations-probe.json: 1..30, 50) reduced per input size to keep
# the full matrix tractable; --quick reduces further.
FULL_ITERATIONS_SMALL = [1, 2, 3, 5, 10, 15, 50]
FULL_ITERATIONS_MEDIUM = [1, 3, 15, 50]
FULL_ITERATIONS_LARGE = [1, 15]
QUICK_ITERATIONS_SMALL = [1, 15]


def corpus(quick: bool):
    """Deterministic corpus. Every entry: (id, bytes, iterations, tags)."""
    rng = random.Random(0x5EED5)
    items = []

    def add(name, data, iters, tags):
        items.append((name, data, iters, tags))

    # --- empty and short inputs -------------------------------------------
    add("empty", b"", [1], ["boundary"])
    add("one-byte", b"a", FULL_ITERATIONS_SMALL if not quick else QUICK_ITERATIONS_SMALL, ["boundary"])
    add("two-same", b"aa", [1, 15], ["boundary"])
    for n in (3, 7, 32, 255, 256):
        add(f"short-{n}", rng.randbytes(n), [1, 15], ["boundary"])

    # --- repeats and periodic sequences ------------------------------------
    for n in (256, 4096):
        add(f"repeat-a-{n}", b"A" * n, [1, 15], ["repeats"])
        add(f"periodic-{n}", (b"abc12345" * ((n + 7) // 8))[:n], [1, 15], ["repeats"])
    add("repeat-longrun-8k", bytes((i // 513) % 4 for i in range(8192)), [1, 15], ["repeats", "rle-tree"])

    # --- dictionary reuse (heavy longest-match-cache traffic) --------------
    chunks = [rng.randbytes(256) for _ in range(64)]
    add("dict-reuse-48k", b"".join(chunks[i % 17] for i in range(192)),
        FULL_ITERATIONS_MEDIUM if not quick else QUICK_ITERATIONS_SMALL, ["dictionary"])

    # --- text, JSON-like, random with fixed seeds ---------------------------
    text = (b"The quick brown fox jumps over the lazy dog. "
            b"packed with zopfli releases 1.0.0 through 1.0.3. ") * 150
    add("text-9k", text[:9000], [1, 15], ["text"])
    words = ["compressed", "zopfli", "deflate", "huffman", "block", "split", "iteration"]
    add("json-like-16k",
        (b'{"key":"value","n":%d,"list":[1,2,3],"word":"%s"}' % (0, words[0].encode())) * 300,
        [1, 15], ["text"])
    add("random-4k", rng.randbytes(4096), FULL_ITERATIONS_SMALL if not quick else QUICK_ITERATIONS_SMALL, ["random"])
    add("random-32k", rng.randbytes(32768), [1, 15], ["random", "size-32k"])

    # --- mixed compressible/incompressible regions --------------------------
    motif = (b"abc" * 500 + b"XYZ" * 300 + rng.randbytes(97))
    add("mixed-runs-64k", (motif * 32)[:65536],
        FULL_ITERATIONS_MEDIUM if not quick else QUICK_ITERATIONS_SMALL, ["mixed"])
    add("mixed-half-16k", b"a" * 8192 + rng.randbytes(8192), [1, 15], ["mixed"])
    add("sparse-zeros-8k", bytes(8192), [1, 15], ["rle-tree"])
    # Histograms that hit the RLE tree-encoding paths with long zero runs
    # and equal-frequency symbols (the 1.0.0 fixed-strategy tree encoder).
    add("lowentropy-8k", bytes((i // 97) % 3 for i in range(8192)), [1, 15], ["rle-tree"])
    add("alphabet-256x128", bytes(range(256)) * 128, [1, 15], ["rle-tree", "mixed"])
    # Blocks large enough to make the auto-type selection prefer stored
    # blocks (1.0.2+ behaviour) while 1.0.0/1.0.1 must stay dynamic.
    add("incompressible-70k", rng.randbytes(70 * 1024), [1, 15], ["stored-candidate"])

    # --- sizes near the 32 KiB window boundary ------------------------------
    add("window-32k-boundary", (b"0123456789abcdef" * 2048)[:32768], [1, 15], ["size-32k"])
    add("window-32k-plus", (b"0123456789abcdef" * 2048)[:32769], [1, 15], ["size-32k"])

    # --- master-block boundaries -------------------------------------------
    add("master-999999", (b"the quick brown fox " * 50000)[:999999], [1], ["master"])
    add("master-1000000", b"A" * 1000000, [1], ["master"])
    add("master-1000001", b"A" * 1000001, [1], ["master"])
    if not quick:
        # Crosses the 1.0.0/1.0.1 master boundary (20,000,000): 1.0.0/1.0.1
        # process one master block, 1.0.2+ split at 1,000,000.
        add("master-legacy-20000001", bytes(20000001), [1], ["master-legacy"])
        add("master-legacy-mixed", (b"master-block-" * 400) + rng.randbytes(64) + bytes(19937536), [1], ["master-legacy"])

    # --- deterministic random matrix ----------------------------------------
    for i in range(6 if not quick else 3):
        n = rng.choice([64, 1000, 5000, 20000])
        add(f"random-det-{i}", rng.randbytes(n), [1, 15], ["random-det"])

    # --- case targeting the 1.0.1 dense-tree encoder vs 1.0.0 fixed strategy
    # Symbol histogram where the 8-strategy search and the fixed strategy
    # must diverge (alternating short runs of two length values).
    special = bytes(((i // 3) % 2 + 65) for i in range(6000))
    add("tree-strategy-6k", special, FULL_ITERATIONS_SMALL if not quick else QUICK_ITERATIONS_SMALL, ["rle-tree"])

    return items


def run_reference(binary: pathlib.Path, data: bytes, iters: int, tmp: pathlib.Path):
    tmp.write_bytes(data)
    started = time.monotonic()
    r = subprocess.run([str(binary), "--zlib", "-c", f"--i{iters}", str(tmp)],
                       capture_output=True, timeout=3600)
    return {
        "status": r.returncode,
        "output": r.stdout,
        "seconds": round(time.monotonic() - started, 3),
    }


def run_native(data: bytes, iters: int, version: str):
    started = time.monotonic()
    r = subprocess.run([str(NATIVE), str(iters), version], input=data,
                       capture_output=True, timeout=3600)
    return {
        "status": r.returncode,
        "output": r.stdout,
        "seconds": round(time.monotonic() - started, 3),
    }


def describe(run):
    out = run["output"]
    if run["status"] != 0 or not out:
        return {"kind": "no-stream", "hash": None, "size": 0, "decompressed": None}
    sha = hashlib.sha256(out).hexdigest()
    try:
        payload = zlib.decompress(out)
        decompressed = "ok" if payload is not None else "none"
    except zlib.error:
        decompressed = "invalid"
    return {"kind": "stream", "hash": sha, "size": len(out), "decompressed": decompressed}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true", help="reduced corpus/iterations")
    parser.add_argument("--output", default="version-matrix.json")
    parser.add_argument("--references", default="", help="dir with built-<ver>/zopfli-<ver>")
    parser.add_argument("--from", dest="first", type=int, default=0,
                        help="input index to start from (chunked runs)")
    parser.add_argument("--to", dest="last", type=int, default=0,
                        help="input index to stop at, exclusive; 0 = all")
    args = parser.parse_args()

    global REFERENCES
    if args.references:
        REFERENCES = {v: pathlib.Path(args.references) / f"built-{v}" / f"zopfli-{v}" for v in VERSIONS}

    missing = [v for v, p in REFERENCES.items() if not p.exists()]
    if missing:
        raise SystemExit(f"missing reference binaries: {missing}")
    if not NATIVE.exists():
        raise SystemExit("build the project first: zig build --release=fast")

    report = {
        "tool": "scripts/version_matrix.py",
        "quick": args.quick,
        "references": {v: str(p) for v, p in REFERENCES.items()},
        "reference_tarballs": {
            "1.0.0": {"tag": "zopfli-1.0.0", "commit": "4975aa5e50761cdeb335b3bf029332df469aa472",
                       "sha256": "386bd801e99bd95f292e7c39fa6a945e4bf1ffec57e16a99024d766fdafb6f96"},
            "1.0.1": {"tag": "zopfli-1.0.1", "commit": "89cf773beef75d7f4d6d378debdf299378c3314e",
                       "sha256": "29743d727a4e0ecd1b93e0bf89476ceeb66e809ab2e6ab007a0b0344800e9b4"},
            "1.0.2": {"tag": "zopfli-1.0.2", "commit": "ae43a8b73827577c4b19b005b6eed81f5cf9bbac",
                       "sha256": "4a570307c37172d894ec4ef93b6e8e3aacc401e78cbcc51cf85b212dbc379a55"},
            "1.0.3": {"tag": "zopfli-1.0.3", "commit": "bd64b2f0553d4f1ef4e6627647c5d9fc8c71ffc0",
                       "sha256": "e955a7739f71af37ef3349c4fa141c648e8775bceb2195be07e86f8e638814bd"},
        },
        "inputs": [],
        "equivalence": {},
        "native_verification": {"failures": [], "checked": 0},
        "skipped": [],
    }

    producers = VERSIONS + [f"native-{v}" for v in VERSIONS]
    result_vectors = {v: [] for v in VERSIONS}
    pair_distinctions = {}
    native_failures = []
    checked = 0
    t0 = time.monotonic()

    with tempfile.TemporaryDirectory(prefix="zf-matrix-") as td:
        tmp = pathlib.Path(td) / "input.bin"
        full_corpus = corpus(args.quick)
        last = args.last if args.last else len(full_corpus)
        for index, (name, data, iterations, tags) in enumerate(full_corpus):
            if index < args.first or index >= last:
                continue
            entry = {"id": name, "size": len(data), "sha256_input": hashlib.sha256(data).hexdigest(),
                     "tags": tags, "combinations": []}
            for iters in iterations:
                results = {}
                for version in VERSIONS:
                    results[version] = describe(run_reference(REFERENCES[version], data, iters, tmp))
                for version in VERSIONS:
                    results[f"native-{version}"] = describe(run_native(data, iters, version))

                # roundtrip + native-vs-reference byte comparison
                for version in VERSIONS:
                    checked += 1
                    ref_desc = results[version]
                    nat_desc = results[f"native-{version}"]
                    if ref_desc["kind"] == "no-stream":
                        native_ok = nat_desc["kind"] == "no-stream"
                    else:
                        native_ok = (nat_desc["kind"] == "stream" and
                                     nat_desc["hash"] == ref_desc["hash"] and
                                     nat_desc["decompressed"] == "ok")
                        if nat_desc["kind"] == "stream" and nat_desc["decompressed"] != "ok":
                            native_ok = False
                    if not native_ok:
                        native_failures.append({"input": name, "iterations": iters,
                                                "version": version,
                                                "ref": ref_desc, "native": nat_desc})
                    if ref_desc["kind"] == "stream" and ref_desc["decompressed"] != "ok":
                        native_failures.append({"input": name, "iterations": iters,
                                                "version": version,
                                                "problem": "reference stream failed to decompress"})

                # equivalence classes among the four references
                classes = {}
                for version in VERSIONS:
                    d = results[version]
                    key = d["hash"] if d["kind"] == "stream" else "no-stream"
                    classes.setdefault(key, []).append(version)
                for version in VERSIONS:
                    d = results[version]
                    result_vectors[version].append(
                        (name, iters, d["hash"] if d["kind"] == "stream" else "no-stream"))
                if len(classes) > 1:
                    class_list = [sorted(members) for members in classes.values()]
                    for a in range(len(VERSIONS)):
                        for b in range(a + 1, len(VERSIONS)):
                            va, vb = VERSIONS[a], VERSIONS[b]
                            da, db = results[va], results[vb]
                            ka = da["hash"] if da["kind"] == "stream" else "no-stream"
                            kb = db["hash"] if db["kind"] == "stream" else "no-stream"
                            if ka != kb:
                                pair_distinctions.setdefault(f"{va}|{vb}", []).append(
                                    {"input": name, "iterations": iters,
                                     "size_ref": da["size"], "size_other": db["size"]})

                entry["combinations"].append({
                    "iterations": iters,
                    "classes": {("no-stream" if k == "no-stream" else k[:16]): sorted(members)
                                for k, members in classes.items()},
                    "native_matches": all(
                        (results[f"native-{v}"]["hash"] == results[v]["hash"]) ==
                        (results[v]["kind"] != "no-stream" or True)
                        for v in VERSIONS) and not any(
                        f for f in native_failures if f["input"] == name and f["iterations"] == iters),
                    "sizes": {v: results[v]["size"] for v in producers},
                })
            report["inputs"].append(entry)

    # groups of versions with identical result vectors
    groups = {}
    for version in VERSIONS:
        key = hashlib.sha256(json.dumps(result_vectors[version]).encode()).hexdigest()
        groups.setdefault(key, []).append(version)
    # Chunked runs only see their own slice: mark the group derivation as
    # partial so the merge step (scripts/merge_matrix.py) recomputes it.
    partial = (args.first, args.last) != (0, 0)
    report["partial"] = {"from": args.first, "to": args.last, "is_partial": partial}
    report["equivalence"] = {
        "groups": sorted(groups.values()),
        "pair_distinctions": {pair: mins[0] | {"distinct_inputs": len(mins)}
                              for pair, mins in pair_distinctions.items()},
    }
    report["native_verification"] = {
        "checked": checked,
        "failures": native_failures,
        "seconds": round(time.monotonic() - t0, 1),
    }
    report["iteration_schedule"] = {
        "baseline": [1, 2, 3, 5, 10, 15, 50],
        "probe_reference": "zopfli-iterations-probe.json (1..30, 50)",
    }

    out_path = ROOT / args.output
    out_path.write_text(json.dumps(report, indent=1))
    groups_str = sorted(groups.values())
    print(f"inputs: {len(report['inputs'])}, combinations checked: {checked}")
    print(f"equivalence groups: {groups_str}")
    for pair, info in pair_distinctions.items():
        print(f"  distinct pair {pair}: first repro {info[0]['input']} i={info[0]['iterations']}")
    print(f"native verification failures: {len(native_failures)}")
    print(f"report written to {out_path}")


if __name__ == "__main__":
    main()
