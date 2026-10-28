#!/usr/bin/env python3
"""Replays captured aapt2 invocations with another aapt2 and compares every output file.

usage: replay.py <capture dir> <aapt2> <android.jar> <results dir> [jobs]

Each run executes at the absolute paths of the original run (aapt2 records source paths in its
outputs), so this is meant to run in a throwaway container.
"""
import concurrent.futures
import hashlib
import json
import os
import shutil
import subprocess
import sys

capture, aapt2, android_jar, results = sys.argv[1:5]
jobs = int(sys.argv[5]) if len(sys.argv) > 5 else os.cpu_count()
cas = os.path.join(capture, "cas")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def materialize(path, digest):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.replay"
    if digest.startswith("external:"):
        rel = digest[len("external:"):]
        if rel.endswith("/android.jar"):
            shutil.copyfile(android_jar, tmp)
        else:
            raise RuntimeError(f"unknown external input {rel}")
    else:
        shutil.copyfile(os.path.join(cas, digest), tmp)
    os.replace(tmp, path)


def compile_output_name(src):
    """aapt2 compile's output file name for a resource file: <dir>_<file>.flat, values as .arsc."""
    parent, base = os.path.basename(os.path.dirname(src)), os.path.basename(src)
    if parent.startswith("values"):
        return f"{parent}_{os.path.splitext(base)[0]}.arsc.flat"
    return f"{parent}_{base}.flat"


def replay(name):
    run = json.load(open(os.path.join(capture, "runs", name)))
    argv, cwd = run["argv"], run["cwd"]
    if argv[0] == "compile":
        # The busybox compiles files concurrently into one directory, so the capture may have
        # picked up the outputs of neighbouring invocations; keep the one this invocation writes.
        want = {compile_output_name(p) for p in run["inputs"]}
        run["outputs"] = {p: d for p, d in run["outputs"].items() if os.path.basename(p) in want}
    os.makedirs(cwd, exist_ok=True)
    out_files = set(run["outputs"])
    for o in run["output_args"]:
        is_dir = any(f.startswith(o + "/") for f in out_files) or (argv[0] == "compile" and o not in out_files)
        os.makedirs(o if is_dir else os.path.dirname(o), exist_ok=True)
    for o in out_files:
        if os.path.isfile(o):
            os.remove(o)
    p = subprocess.run([aapt2] + argv, cwd=cwd, capture_output=True)
    res = {"run": name, "cmd": argv[0] if argv else "", "exit_expected": run["exit"], "exit": p.returncode,
           "outputs": len(out_files), "mismatch": [], "missing": []}
    for o, d in run["outputs"].items():
        if not os.path.isfile(o):
            res["missing"].append(o)
            continue
        got = sha256(o)
        if got != d:
            res["mismatch"].append(o)
            keep = os.path.join(results, "mismatch", name, o.lstrip("/"))
            os.makedirs(os.path.dirname(keep), exist_ok=True)
            shutil.copyfile(o, keep)
    if p.returncode != run["exit"] or res["mismatch"] or res["missing"]:
        res["stderr"] = p.stderr.decode(errors="replace")[-2000:]
    return res


def main():
    os.makedirs(results, exist_ok=True)
    names = sorted(os.listdir(os.path.join(capture, "runs")))
    runs = {n: json.load(open(os.path.join(capture, "runs", n))) for n in names}
    # Files one run writes and another reads (link output -> convert input) come from the replay
    # itself, and their readers run afterwards. Every other input is materialized up front.
    produced = {p for r in runs.values() for p in r["outputs"]}
    inputs = {}
    for r in runs.values():
        for p, d in r["inputs"].items():
            if p in produced:
                continue
            if inputs.setdefault(p, d) != d:
                raise SystemExit(f"{p} has different contents in different runs")
    for p, d in inputs.items():
        materialize(p, d)
    later = [n for n, r in runs.items() if any(p in produced for p in r["inputs"])]
    first = [n for n in names if n not in later]
    totals = {"runs": 0, "outputs": 0, "ok": 0, "bad": 0}
    by_cmd = {}
    with open(os.path.join(results, "results.jsonl"), "w") as out, \
            concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for res in list(ex.map(replay, first)) + list(ex.map(replay, later)):
            out.write(json.dumps(res) + "\n")
            totals["runs"] += 1
            totals["outputs"] += res["outputs"]
            good = res["exit"] == res["exit_expected"] and not res["mismatch"] and not res["missing"]
            totals["ok" if good else "bad"] += 1
            c = by_cmd.setdefault(res["cmd"], {"runs": 0, "outputs": 0, "bad": 0})
            c["runs"] += 1
            c["outputs"] += res["outputs"]
            c["bad"] += 0 if good else 1
    summary = {"totals": totals, "by_command": by_cmd}
    json.dump(summary, open(os.path.join(results, "summary.json"), "w"), indent=1)
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
