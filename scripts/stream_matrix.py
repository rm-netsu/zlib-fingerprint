#!/usr/bin/env python3
"""Streaming-API differential matrix across all official zlib releases.

The one-shot census (equivalence_matrix.py) covers only the whole-input /
single-Z_FINISH producer model. This tool exercises the deferred streaming
surface from BACKLOG.md:

  * flush operations Z_PARTIAL_FLUSH / Z_SYNC_FLUSH / Z_FULL_FLUSH / Z_BLOCK
    at byte offsets (mode ``marks``) and after every input chunk (``every``);
  * input chunking 1..65535 combined with capped avail_out 1..65536
    (mode ``one`` with inchunk/outchunk), including the output-buffer
    sensitive 1.2.9/1.2.10 boundary;
  * mid-stream deflateParams level/strategy switches (``params``);
  * deflateSetDictionary with short and window-exceeding dictionaries
    (``dict``, FDICT header);
  * deflateReset (``reset``) and deflateCopy source/clone continuation
    (``copy`` / ``copy2``) with self-consistency checks against ``one``;
  * cross-check that the new streaming wrapper reproduces the historical
    one-shot wrapper byte for byte (``oneshotref``).

Every scenario is run with every version-specific ``zstream-<ver>`` binary;
the per-version signature (status + output length + SHA-256) is compared,
observed classes are derived, canonical-class cohesion under streaming is
verified for ALL member releases, and first-difference witnesses are
recorded for the eight release-boundary pairs.

Subcommands:
  stream    run the streaming scenario matrix  -> stream-matrix.json
  oneshot   extended one-shot matrix (full depth, boundary fixtures,
            multi-MiB inputs) via the original zlib-<ver> wrappers
            -> oneshot-ext-results.json
"""
import argparse
import hashlib
import itertools
import json
import os
import pathlib
import platform
import random
import subprocess
import sys
import time
import zlib
from concurrent.futures import ThreadPoolExecutor

Z_PARTIAL_FLUSH, Z_SYNC_FLUSH, Z_FULL_FLUSH, Z_BLOCK = 1, 2, 3, 5

CLASSES = {
    "A": ["1.0.1", "1.0.2", "1.0.4", "1.0.5"],
    "B": ["1.0.6", "1.0.7", "1.0.8", "1.0.9"],
    "C": ["1.1.0", "1.1.1", "1.1.2", "1.1.3", "1.1.4", "1.2.0"],
    "D": ["1.2.1", "1.2.2"],
    "E": ["1.2.3"],
    "F": ["1.2.4", "1.2.5", "1.2.6", "1.2.7", "1.2.8"],
    "G": ["1.2.9"],
    "H": ["1.2.10", "1.2.11", "1.2.12", "1.2.13", "1.3", "1.3.1", "1.3.2"],
}
BOUNDARY_PAIRS = [("1.0.2", "1.0.4"), ("1.0.5", "1.0.6"), ("1.0.9", "1.1.0"),
                  ("1.1.0", "1.1.1"), ("1.2.0", "1.2.1"), ("1.2.2", "1.2.3"),
                  ("1.2.3", "1.2.4"), ("1.2.5", "1.2.6"), ("1.2.8", "1.2.9"),
                  ("1.2.9", "1.2.10"), ("1.2.10", "1.2.11"),
                  ("1.2.11", "1.2.12"), ("1.3.1", "1.3.2"), ("1.3.2", "1.4")]


# --------------------------------------------------------------------------
# Deterministic fixture corpus
# --------------------------------------------------------------------------
def _mixed(size, seed):
    rng = random.Random(seed)
    out = bytearray()
    while len(out) < size:
        r = rng.random()
        if r < 0.35:
            out += bytes([rng.randrange(256)]) * 300
        elif r < 0.70:
            out += b"The quick brown fox jumps over the lazy dog. " * 8
        else:
            out += rng.randbytes(256)
    return bytes(out[:size])


def _match_boundary(seed):
    """Repeats of length 2/3/4 (MIN_MATCH boundary) and 257/258/259
    (MAX_MATCH boundary) between fresh random blocks."""
    rng = random.Random(seed)
    parts = []
    for _ in range(3):
        for length in (2, 3, 4, 257, 258, 259):
            block = rng.randbytes(96)
            parts.append(block)
            parts.append(block[:length])
    parts.append(rng.randbytes(64))
    return b"".join(parts)


def fixtures():
    rng = random.Random(0x5A5A5A5A)
    fx = {}
    fx["empty"] = b""
    fx["repeat-100"] = b"A" * 100
    fx["periodic-1000"] = (b"abc12345" * 128)[:1000]
    fx["random-2000"] = rng.randbytes(2000)
    words = [b"lorem", b"ipsum", b"dolor", b"sit", b"amet", b"zlib",
             b"deflate", b"historicus", b"stream", b"flush"]
    text = b" ".join(words[rng.randrange(len(words))] for _ in range(700))
    fx["text-4096"] = (text * 8)[:4096]
    fx["mixed-4096"] = _mixed(4096, 0xC0FFEE)
    fx["repeat-65535"] = b"A" * 65535
    fx["periodic-65536"] = b"abc12345" * 8192
    fx["mixed-65536"] = _mixed(65536, 0xBADF00D)
    fx["text-65536"] = (fx["text-4096"] * 16)[:65536]
    fx["periodic-131072"] = (b"abc123\x00\xff" * 16384)
    fx["mixed-70000"] = _mixed(70000, 0x70000)
    mb = _match_boundary(0x1234ABCD)
    fx[f"matchb-{len(mb)}"] = mb
    # Exact literal-count fixtures hitting lit_bufsize boundaries at
    # memLevel 1 (128 symbols) and memLevel 8 (16384 symbols).
    lit_rng = random.Random(0x1A2B3C4D)
    for n in (126, 127, 128, 129, 130,
              16382, 16383, 16384, 16385, 16386):
        fx[f"lit-{n}"] = lit_rng.randbytes(n)
    return fx


# --------------------------------------------------------------------------
# Scenario definitions (stream subcommand)
# --------------------------------------------------------------------------
def scenarios(fx):
    S = []

    def add(group, fixture, mode, params, timeout=15, dictlen=None):
        S.append({"group": group, "fixture": fixture, "mode": mode,
                  "params": tuple(params), "dictlen": dictlen,
                  "timeout": timeout,
                  "args": [mode, *map(str, params)]})

    # --- flush at byte offsets ---
    for fix in ("periodic-65536", "mixed-4096"):
        length = len(fx[fix])
        for lvl in (0, 1, 6, 9):
            for fl in (Z_PARTIAL_FLUSH, Z_SYNC_FLUSH, Z_FULL_FLUSH, Z_BLOCK):
                add("flush", fix, "marks",
                    (lvl, 8, 0, 15, 0, 0, fl, length // 3, 2 * length // 3))

    # --- flush after every input chunk ---
    for fix in ("periodic-1000", "text-4096"):
        for lvl in (1, 6):
            for mem in (1, 8):
                for inch in (7, 64):
                    for fl in (Z_PARTIAL_FLUSH, Z_SYNC_FLUSH,
                               Z_FULL_FLUSH, Z_BLOCK):
                        add("every", fix, "every",
                            (lvl, mem, 0, 15, inch, 0, fl))

    # --- input chunking x output cap ---
    # 64 KiB boundary fixtures: chunk sizes that keep the run count sane;
    # the extreme 1/2-byte chunks run on the 4 KiB fixture below.
    for fix in ("repeat-65535", "periodic-65536"):
        for lvl in (0, 1, 6, 9):
            for inch in (0, 64, 512, 16384, 65535):
                for outc in (0, 1, 2, 16, 64, 512, 4096, 32768, 65536):
                    add("chunk", fix, "one", (lvl, 8, 0, 15, inch, outc))
    for lvl in (0, 1, 6, 9):
        for inch in (1, 2, 64, 512, 16384):
            for outc in (0, 1, 16, 512, 65536):
                add("chunk", "mixed-4096", "one", (lvl, 8, 0, 15, inch, outc))
    # the output-buffer sensitive empty/short stored cases (1.2.9/1.2.10)
    for fix in ("empty", "repeat-100"):
        for mem in (1, 8):
            for wb in (9, 15):
                for outc in (1, 16, 64, 512):
                    add("chunk", fix, "one", (0, mem, 0, wb, 0, outc))

    # --- mid-stream deflateParams ---
    transitions = [((6, 0), (1, 0)), ((6, 0), (9, 0)), ((9, 0), (0, 0)),
                   ((1, 0), (6, 0)), ((6, 0), (6, 3)), ((6, 0), (6, 4)),
                   ((0, 0), (6, 0)), ((0, 0), (1, 0))]
    for fix in ("periodic-65536", "mixed-4096"):
        length = len(fx[fix])
        for mem in (1, 8):
            for (l1, s1), (l2, s2) in transitions:
                for outc in (0, 64):
                    add("params", fix, "params",
                        (l1, mem, s1, 15, 0, outc, length // 2, l2, s2))

    # --- dictionaries (FDICT) ---
    for dl in (3, 32, 512, 32768):
        for lvl in (1, 6, 9):
            add("dict", "text-65536", "dict",
                (lvl, 8, 0, 15, 0, 0, dl), dictlen=dl)
    add("dict", "mixed-70000", "dict", (6, 8, 0, 15, 0, 0, 70000),
        dictlen=70000, timeout=30)
    add("dict", "text-65536", "dict", (6, 8, 0, 9, 0, 0, 512), dictlen=512)

    # --- reset / copy, with self-consistency companions ---
    for fix in ("periodic-65536", "mixed-4096"):
        length = len(fx[fix])
        for lvl in (1, 6, 9):
            add("resetcopy", fix, "one", (lvl, 8, 0, 15, 0, 0))
            add("resetcopy", fix, "reset", (lvl, 8, 0, 15, 0, 0))
            add("resetcopy", fix, "copy", (lvl, 8, 0, 15, 0, 0, length // 2))
            add("resetcopy", fix, "copy2", (lvl, 8, 0, 15, 0, 0, length // 2))
    # chunked interplay
    add("resetcopy", "periodic-65536", "one", (6, 8, 0, 15, 997, 777))
    add("resetcopy", "periodic-65536", "reset", (6, 8, 0, 15, 997, 777))
    add("resetcopy", "periodic-65536", "copy", (6, 8, 0, 15, 997, 777, 32768))
    add("resetcopy", "periodic-65536", "copy2", (6, 8, 0, 15, 997, 777, 32768))

    # --- reference cross-check vs the historical one-shot wrapper ---
    # "oneshot" presents all input in a single Z_FINISH call sequence,
    # exactly like zlib_wrapper.c; a mismatch here means a wrapper bug.
    for fix in ("empty", "repeat-65535", "periodic-65536", "mixed-4096"):
        for lvl in (0, 1, 6, 9):
            add("oneshotref", fix, "oneshot", (lvl, 8, 0, 15, 0, 0),
                timeout=30 if lvl == 9 else 15)
    return S


# --------------------------------------------------------------------------
# Probe helpers
# --------------------------------------------------------------------------
def probe(exe, args, payload, timeout):
    try:
        proc = subprocess.run((str(exe), *args), input=payload,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, b"", b""


def parse_status(stderr):
    for line in stderr.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                pass
    return None


def first_diff(a, b):
    if a == b:
        return None
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return {"offset": i,
                    "a": a[max(0, i - 2):i + 6].hex(),
                    "b": b[max(0, i - 2):i + 6].hex()}
    return {"offset": n, "a": a[n:n + 8].hex(), "b": b[n:n + 8].hex()}


def roundtrip_ok(out, payload, dictlen):
    """Returns (ok, reason). reason is "" on success."""
    try:
        if dictlen:
            dec = zlib.decompressobj(wbits=15, zdict=payload[:dictlen])
            if dec.decompress(out) + dec.flush() != payload:
                return False, "decompressed to different bytes"
        elif zlib.decompress(out) != payload:
            return False, "decompressed to different bytes"
        return True, ""
    except zlib.error as ex:
        return False, str(ex)


# --------------------------------------------------------------------------
# stream subcommand
# --------------------------------------------------------------------------
def run_stream(args, jobs):
    fx = fixtures()
    S = scenarios(fx)
    if args.only_groups:
        keep = set(args.only_groups.split(","))
        S = [s for s in S if s["group"] in keep]
    bin_dir = pathlib.Path(args.bin_dir)
    exes = sorted(bin_dir.glob("zstream-*"))
    exes = [p for p in exes if p.is_file() and os.access(p, os.X_OK)]
    if len(exes) < 2:
        sys.exit("No zstream-<ver> binaries found; run "
                 "ZLIB_ONLY=1 binaries/build-binaries.sh first")
    versions = [p.name.removeprefix("zstream-") for p in exes]
    present = set(versions)

    # companion lookup for self-consistency
    by_key = {(s["fixture"], s["mode"], s["params"]): i
              for i, s in enumerate(S)}

    signatures = {v: hashlib.sha256() for v in versions}
    group_stats = {}
    pair_stats = {f"{a} / {b}": {"shared_success": 0, "output_diffs": 0,
                                 "status_diffs": 0}
                  for a, b in BOUNDARY_PAIRS}
    first_diffs = {}
    first_status = {}
    split_witnesses = []
    selfcheck_results = []
    oneshotref_mismatches = []
    roundtrip_failures = []
    outputs = [None] * len(S)  # kept only transiently per scenario index
    started = time.monotonic()
    run_count = 0

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for idx, scn in enumerate(S):
            payload = fx[scn["fixture"]]
            results = list(pool.map(
                lambda exe: probe(exe, scn["args"], payload, scn["timeout"]),
                exes))
            run_count += len(results)
            outs = {}
            for ver, (rc, out, err) in zip(versions, results):
                digest = hashlib.sha256(out).hexdigest()
                signatures[ver].update(rc.to_bytes(4, "big", signed=True))
                signatures[ver].update(len(out).to_bytes(8, "big"))
                signatures[ver].update(digest.encode())
                outs[ver] = (rc, len(out), digest, out)
            outputs[idx] = outs

            # canonical-class cohesion under this scenario (all members)
            for cls, members in CLASSES.items():
                present_members = [m for m in members if m in present]
                if len(present_members) < 2:
                    continue
                sigs = {m: outs[m][:3] for m in present_members}
                if len(set(sigs.values())) > 1:
                    rcs = {s[0] for s in sigs.values()}
                    split_witnesses.append({
                        "group": scn["group"], "fixture": scn["fixture"],
                        "args": scn["args"], "class": cls,
                        "kind": "status" if len(rcs) > 1 else "bytes",
                        "signatures": {m: list(sigs[m])
                                       for m in present_members}})

            # boundary pairs
            for a, b in BOUNDARY_PAIRS:
                if a not in present or b not in present:
                    continue
                ra, rb = outs[a], outs[b]
                key = f"{a} / {b}"
                if ra[0] == 0 and rb[0] == 0:
                    pair_stats[key]["shared_success"] += 1
                    if ra[3] != rb[3]:
                        pair_stats[key]["output_diffs"] += 1
                        if key not in first_diffs:
                            first_diffs[key] = {
                                "group": scn["group"],
                                "fixture": scn["fixture"],
                                "args": scn["args"],
                                "lengths": [ra[1], rb[1]],
                                "first_diff": first_diff(ra[3], rb[3])}
                elif ra[0] != rb[0]:
                    pair_stats[key]["status_diffs"] += 1
                    if key not in first_status:
                        first_status[key] = {
                            "group": scn["group"],
                            "fixture": scn["fixture"],
                            "args": scn["args"],
                            "status": [ra[0], rb[0]]}

            # round-trip every successful stream
            for ver, (rc, out, err) in zip(versions, results):
                if rc == 0 and out:
                    ok, why = roundtrip_ok(out, payload, scn["dictlen"])
                    if not ok:
                        roundtrip_failures.append(
                            {"group": scn["group"], "fixture": scn["fixture"],
                             "args": scn["args"], "version": ver,
                             "error": why})

            # self-consistency: reset/copy/copy2 vs companion one-scenario
            if scn["mode"] in ("reset", "copy", "copy2"):
                lvl, mem, strat, wb, inch, outc = scn["params"][:6]
                comp = by_key.get((scn["fixture"], "one",
                                   (lvl, mem, strat, wb, inch, outc)))
                if comp is not None and outputs[comp] is not None:
                    for ver in versions:
                        a = outputs[comp][ver]
                        b = outs[ver]
                        ok = (a[0] == b[0] == 0 and a[3] == b[3])
                        selfcheck_results.append({
                            "mode": scn["mode"], "fixture": scn["fixture"],
                            "params": list(scn["params"]), "version": ver,
                            "equal": ok})

            # reference cross-check against the one-shot wrapper
            if scn["group"] == "oneshotref":
                lvl, mem, strat, wb = scn["params"][:4]
                ref_exes = [bin_dir / f"zlib-{v}" for v in versions]
                ref_results = list(pool.map(
                    lambda exe: probe(exe, [str(lvl), str(mem), str(strat),
                                            str(wb)], payload,
                                      scn["timeout"]), ref_exes))
                for ver, (rc, out, err) in zip(versions, ref_results):
                    b = outs[ver]
                    if rc != b[0] or out != b[3]:
                        oneshotref_mismatches.append({
                            "fixture": scn["fixture"],
                            "params": list(scn["params"][:4]),
                            "version": ver, "status": [rc, b[0]],
                            "lengths": [len(out), b[1]]})

            gs = group_stats.setdefault(scn["group"],
                                        {"scenarios": 0, "failures": {}})
            gs["scenarios"] += 1
            for ver, (rc, out, err) in zip(versions, results):
                if rc != 0:
                    gs["failures"][ver] = gs["failures"].get(ver, 0) + 1
            outputs[idx] = None  # free memory
            if (idx + 1) % 40 == 0:
                print(f"[{idx + 1}/{len(S)}] scenarios, "
                      f"{time.monotonic() - started:.0f}s", flush=True)

    # global observed classes over the whole scenario set
    clusters = {}
    for ver, sig in signatures.items():
        clusters.setdefault(sig.hexdigest(), []).append(ver)
    order = {v: i for i, v in enumerate(versions)}
    global_classes = [sorted(members, key=lambda v: order[v])
                      for members in clusters.values()]

    selfcheck_bad = [r for r in selfcheck_results if not r["equal"]]
    report = {
        "tool": "scripts/stream_matrix.py stream",
        "date": time.strftime("%Y-%m-%d"),
        "versions": versions,
        "scenario_count": len(S),
        "run_count": run_count,
        "elapsed_seconds": round(time.monotonic() - started, 1),
        "canonical_classes": CLASSES,
        "global_classes": global_classes,
        "class_split_witnesses": split_witnesses,
        "boundary_pair_stats": pair_stats,
        "first_output_differences": first_diffs,
        "first_status_differences": first_status,
        "selfcheck_total": len(selfcheck_results),
        "selfcheck_mismatches": selfcheck_bad,
        "oneshotref_mismatches": oneshotref_mismatches,
        "roundtrip_failures": roundtrip_failures,
        "group_stats": group_stats,
        "note": ("Streaming-API differential over the listed scenarios; "
                 "observed classes are finite evidence, not a proof for "
                 "every possible call sequence."),
    }
    pathlib.Path(args.out).write_text(json.dumps(report, indent=2),
                                      encoding="utf-8")
    print(f"scenarios={len(S)} runs={run_count} "
          f"elapsed={report['elapsed_seconds']}s", flush=True)
    print(f"class splits under streaming: {len(split_witnesses)}", flush=True)
    print(f"selfcheck mismatches: {len(selfcheck_bad)}", flush=True)
    print(f"oneshotref mismatches: {len(oneshotref_mismatches)}", flush=True)
    print(f"round-trip failures: {len(roundtrip_failures)}", flush=True)
    print(f"Saved {args.out}", flush=True)


# --------------------------------------------------------------------------
# oneshot subcommand (extended one-shot matrix via zlib-<ver> wrappers)
# --------------------------------------------------------------------------
def run_oneshot(args, jobs):
    fx = fixtures()
    bin_dir = pathlib.Path(args.bin_dir)
    exes = sorted(bin_dir.glob("zlib-*"))
    exes = [p for p in exes
            if p.is_file() and os.access(p, os.X_OK)
            and not p.name.startswith("zlib-ng")]
    if len(exes) < 2:
        sys.exit("No zlib-<ver> one-shot wrappers found")
    versions = [p.name.removeprefix("zlib-") for p in exes]
    present = set(versions)

    small = ["empty", "repeat-100", "periodic-1000", "random-2000",
             "text-4096", "mixed-4096", "repeat-65535", "periodic-65536",
             "mixed-65536", "periodic-131072"]
    small += sorted(k for k in fx if k.startswith(("matchb-", "lit-")))
    big = "mixed-2mib"
    fx[big] = _mixed(2 * 1024 * 1024, 0x2B1B5EED)

    grid = list(itertools.product(range(10), (1, 4, 8, 9), range(5), (9, 15)))
    big_grid = [(1, 8, 0, 15), (6, 8, 0, 15), (9, 8, 0, 15)]

    # Append-only journal so the long run can resume across invocations.
    journal_path = pathlib.Path(args.journal)
    done = {}
    if journal_path.exists():
        for line in journal_path.read_text().splitlines():
            if not line.strip():
                continue
            rec = json.loads(line)
            done[(rec["fixture"], tuple(rec["params"]))] = rec
    journal = journal_path.open("a", encoding="utf-8")

    signatures = {v: hashlib.sha256() for v in versions}
    pair_stats = {f"{a} / {b}": {"shared_success": 0, "output_diffs": 0,
                                 "status_diffs": 0}
                  for a, b in BOUNDARY_PAIRS}
    first_diffs = {}
    split_witnesses = []
    roundtrip_failures = []
    started = time.monotonic()
    probe_count = 0

    def apply_record(fixture, params, record):
        """Feed a finished case record into all accumulators."""
        nonlocal probe_count
        probe_count += 1
        sigs = record["sig"]
        for ver in versions:
            rc, ln, sha = sigs[ver]
            signatures[ver].update(rc.to_bytes(4, "big", signed=True))
            signatures[ver].update(ln.to_bytes(8, "big"))
            signatures[ver].update(sha.encode())
        for cls, members in CLASSES.items():
            pm = [m for m in members if m in present]
            if len(pm) < 2:
                continue
            msigs = {m: tuple(sigs[m]) for m in pm}
            if len(set(msigs.values())) > 1:
                if len(split_witnesses) < 500:
                    rcs = {s[0] for s in msigs.values()}
                    split_witnesses.append({
                        "fixture": fixture, "params": list(params),
                        "class": cls,
                        "kind": "status" if len(rcs) > 1 else "bytes",
                        "signatures": {m: list(msigs[m]) for m in pm}})
        for a, b in BOUNDARY_PAIRS:
            if a not in present or b not in present:
                continue
            ra, rb = sigs[a], sigs[b]
            key = f"{a} / {b}"
            if ra[0] == 0 and rb[0] == 0:
                pair_stats[key]["shared_success"] += 1
                if ra[2] != rb[2]:
                    pair_stats[key]["output_diffs"] += 1
                    if key not in first_diffs:
                        first_diffs[key] = {
                            "fixture": fixture, "params": list(params),
                            "lengths": [ra[1], rb[1]],
                            "first_diff": record.get("fd", {}).get(key)}
            elif ra[0] != rb[0]:
                pair_stats[key]["status_diffs"] += 1
        for ver, err in record.get("rt", []):
            roundtrip_failures.append(
                {"fixture": fixture, "params": list(params),
                 "version": ver, "error": err})

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        def run_case(fixture, params, timeout):
            payload = fx[fixture]
            results = list(pool.map(
                lambda exe: probe(exe, list(map(str, params)), payload,
                                  timeout), exes))
            record = {"fixture": fixture, "params": list(params),
                      "sig": {}, "rt": []}
            outs = {}
            for ver, (rc, out, err) in zip(versions, results):
                record["sig"][ver] = [rc, len(out),
                                      hashlib.sha256(out).hexdigest()]
                outs[ver] = (rc, out)
            for a, b in BOUNDARY_PAIRS:
                if a in present and b in present:
                    ra, oa = outs[a]
                    rb, ob = outs[b]
                    if (ra == rb == 0 and oa != ob
                            and f"{a} / {b}" not in record.setdefault(
                                "fd", {})):
                        record["fd"][f"{a} / {b}"] = first_diff(oa, ob)
            for ver, (rc, out, err) in zip(versions, results):
                if rc == 0 and out:
                    try:
                        if zlib.decompress(out) != payload:
                            record["rt"].append([ver, "different bytes"])
                    except zlib.error as ex:
                        record["rt"].append([ver, str(ex)])
            return record

        for fixture in small + [big]:
            cases = [(fixture, params) for params in
                     (big_grid if fixture == big else grid)]
            fresh = 0
            for fixture_name, params in cases:
                key = (fixture_name, tuple(params))
                if key in done:
                    apply_record(fixture_name, params, done[key])
                    continue
                timeout = 120 if fixture == big else 20
                record = run_case(fixture_name, params, timeout)
                journal.write(json.dumps(record) + "\n")
                journal.flush()
                apply_record(fixture_name, params, record)
                fresh += 1
            print(f"[oneshot] {fixture}: {probe_count} cases total "
                  f"({fresh} fresh), {time.monotonic() - started:.0f}s",
                  flush=True)
    journal.close()

    clusters = {}
    for ver, sig in signatures.items():
        clusters.setdefault(sig.hexdigest(), []).append(ver)
    order = {v: i for i, v in enumerate(versions)}
    global_classes = [sorted(members, key=lambda v: order[v])
                      for members in clusters.values()]
    report = {
        "tool": "scripts/stream_matrix.py oneshot",
        "date": time.strftime("%Y-%m-%d"),
        "versions": versions,
        "depth": "full (levels 0-9, memLevel 1/4/8/9, strategies 0-4, "
                 "windowBits 9/15) on boundary fixtures, plus 2 MiB mixed "
                 "inputs at levels 1/6/9",
        "fixtures": small + [big],
        "probe_count": probe_count,
        "run_count": probe_count * len(versions),
        "elapsed_seconds": round(time.monotonic() - started, 1),
        "global_classes": global_classes,
        "class_split_witnesses": split_witnesses,
        "class_split_count_capped": len(split_witnesses) >= 500,
        "boundary_pair_stats": pair_stats,
        "first_output_differences": first_diffs,
        "roundtrip_failures": roundtrip_failures,
        "note": "Extended one-shot matrix; supersedes the quick depth for "
                "the listed fixtures. Finite evidence, not a proof.",
    }
    pathlib.Path(args.out).write_text(json.dumps(report, indent=2),
                                      encoding="utf-8")
    print(f"probes={probe_count} runs={probe_count * len(versions)} "
          f"elapsed={report['elapsed_seconds']}s", flush=True)
    print(f"class splits: {len(split_witnesses)}, "
          f"round-trip failures: {len(roundtrip_failures)}", flush=True)
    print(f"Saved {args.out}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("stream")
    p1.add_argument("--bin-dir", default="binaries")
    p1.add_argument("--out", default="stream-matrix.json")
    p1.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 2))
    p1.add_argument("--only-groups")

    p2 = sub.add_parser("oneshot")
    p2.add_argument("--bin-dir", default="binaries")
    p2.add_argument("--out", default="oneshot-ext-results.json")
    p2.add_argument("--journal", default="oneshot-ext-journal.jsonl")
    p2.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 2))

    args = parser.parse_args()
    if args.cmd == "stream":
        run_stream(args, args.jobs)
    else:
        run_oneshot(args, args.jobs)


if __name__ == "__main__":
    main()
