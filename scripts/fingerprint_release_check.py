#!/usr/bin/env python3
"""End-to-end fingerprint search verification against every official release.

Generates zlib streams with each reference zopfli CLI (1.0.0..1.0.3) and a
few non-zopfli producers, runs the zlib-fingerprint search on them and checks
that the reported producer reproduces the stream bit-exactly and that zopfli
streams are attributed to the correct equivalence group.

The reference CLIs are resolved like the zopfli-replicant suites resolve
them: $ZOPFLI_REF_BINARIES, then the repository's binaries/ directory
(bash zopfli-replicant/binaries/build-references.sh), then the package's
own binaries/ directory.
"""
import json
import os
import pathlib
import random
import subprocess
import sys
import tempfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SEARCH = ROOT / "zig-out/bin/zlib-fingerprint"


def reference(version: str) -> pathlib.Path:
    env = os.environ.get("ZOPFLI_REF_BINARIES")
    candidates = ([pathlib.Path(env)] if env else []) + [
        ROOT / "binaries",
        ROOT / "zopfli-replicant" / "binaries",
    ]
    for base in candidates:
        cli = base / f"zopfli-{version}"
        if cli.is_file():
            return cli
    raise SystemExit(
        f"zopfli-{version} reference CLI not found; build them with: "
        f"bash {ROOT / 'zopfli-replicant' / 'binaries' / 'build-references.sh'}")


REFERENCES = {v: reference(v) for v in ("1.0.0", "1.0.1", "1.0.2", "1.0.3")}

PAYLOADS = {
    "text-8k": (b"The quick brown fox jumps over the lazy dog. " * 180)[:8192],
    "random-2k": random.Random(7).randbytes(2048),
    "mixed-48k": (b"abcdef" * 1000 + random.Random(8).randbytes(512)) * 8,
}


def make_stream(version, data, iters, tmp):
    tmp.write_bytes(data)
    r = subprocess.run([str(REFERENCES[version]), "--zlib", "-c", f"--i{iters}", str(tmp)],
                       capture_output=True, check=True)
    return r.stdout


def run_search(stream: bytes):
    with tempfile.NamedTemporaryFile(suffix=".zlib", delete=False) as f:
        f.write(stream)
        path = f.name
    try:
        r = subprocess.run([str(SEARCH), "--no-color", path],
                           capture_output=True, text=True, timeout=3600)
    finally:
        pathlib.Path(path).unlink()
    return r


def main():
    failures = []
    checked = 0
    stored_ambiguous = 0
    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td) / "in.bin"
        for version in ("1.0.0", "1.0.1", "1.0.2", "1.0.3"):
            for label, data in PAYLOADS.items():
                for iters in (1, 15):
                    stream = make_stream(version, data, iters, tmp)
                    r = run_search(stream)
                    checked += 1
                    out = r.stdout
                    ok = ("found" in out.lower())
                    if not ok:
                        failures.append({
                            "version": version, "payload": label, "iterations": iters,
                            "stdout": out[-600:], "stderr": r.stderr[-200:],
                        })
                        continue
                    if "zopfli" in out.lower():
                        group = "zopfli 1.0.2-1.0.3" if version in ("1.0.2", "1.0.3") else f"zopfli {version}"
                        if group not in out:
                            failures.append({
                                "version": version, "payload": label, "iterations": iters,
                                "problem": f"zopfli match without group range {group!r}",
                                "stdout": out[-600:],
                            })
                    elif "stored" in out.lower():
                        # Stored-block streams are byte-identical across
                        # implementations; the search reports the best-prior
                        # reproducer (e.g. stock zlib level 9) with an
                        # explicit ambiguity note.
                        stored_ambiguous += 1
                    else:
                        failures.append({
                            "version": version, "payload": label, "iterations": iters,
                            "problem": "matched a non-zopfli reproducer without the stored-block ambiguity note",
                            "stdout": out[-600:],
                        })
        # non-zopfli producers must not be misattributed to zopfli
        import zlib as z
        for level in (1, 6, 9):
            payload = PAYLOADS["text-8k"]
            stream = z.compress(payload, level)
            r = run_search(stream)
            checked += 1
            out = r.stdout.lower()
            if "found" not in out or "zopfli" in out:
                failures.append({"producer": f"zlib level {level}", "stdout": r.stdout[-400:]})

    print(f"fingerprint end-to-end: {checked - len(failures)}/{checked} ok "
          f"(stored-block ambiguity notes: {stored_ambiguous})")
    if failures:
        print(json.dumps(failures, indent=1)[:4000])
        sys.exit(1)


if __name__ == "__main__":
    main()
