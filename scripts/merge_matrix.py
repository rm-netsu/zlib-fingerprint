#!/usr/bin/env python3
"""Merge chunked version-matrix partial reports into the final report.

Recomputes the equivalence groups from the per-input result hashes and unions
the pair distinctions and native verification results.
"""
import hashlib
import json
import pathlib
import sys


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    paths = [pathlib.Path(p) for p in sys.argv[1:]]
    if not paths:
        raise SystemExit("usage: merge_matrix.py partial1.json partial2.json ...")
    reports = [json.loads(p.read_text()) for p in paths]
    merged = dict(reports[0])
    merged["inputs"] = []
    merged["partial"] = {"is_partial": False, "chunks": [str(p.name) for p in paths]}

    all_failures = []
    total_checked = 0
    total_seconds = 0.0
    result_vectors = {"1.0.0": [], "1.0.1": [], "1.0.2": [], "1.0.3": []}
    pair_distinctions = {}
    for chunk_index, rep in enumerate(reports):
        merged["inputs"].extend(rep["inputs"])
        all_failures.extend(rep["native_verification"]["failures"])
        total_checked += rep["native_verification"]["checked"]
        total_seconds += rep["native_verification"].get("seconds", 0)
        for entry in rep["inputs"]:
            for comb in entry["combinations"]:
                for digest, members in comb["classes"].items():
                    for version in members:
                        result_vectors[version].append((entry["id"], comb["iterations"], digest))
        for pair, info in rep["equivalence"]["pair_distinctions"].items():
            existing = pair_distinctions.get(pair)
            # Chunks are given in matrix order: keep the earliest chunk's
            # first reproducible input.
            if existing is None or chunk_index < existing.get("chunk", 99):
                candidate = dict(info)
                candidate["chunk"] = chunk_index
                pair_distinctions[pair] = candidate

    groups = {}
    for version, vector in result_vectors.items():
        key = hashlib.sha256(json.dumps(vector).encode()).hexdigest()
        groups.setdefault(key, []).append(version)
    merged["equivalence"] = {
        "groups": sorted(groups.values()),
        "pair_distinctions": pair_distinctions,
    }
    merged["native_verification"] = {
        "checked": total_checked,
        "failures": all_failures,
        "seconds": round(total_seconds, 1),
    }

    out = root / "version-matrix.json"
    out.write_text(json.dumps(merged, indent=1))
    print(f"merged {len(paths)} chunks: {len(merged['inputs'])} inputs, "
          f"{total_checked} combinations, groups {sorted(groups.values())}, "
          f"failures {len(all_failures)}")
    print(f"report written to {out}")


if __name__ == "__main__":
    main()
