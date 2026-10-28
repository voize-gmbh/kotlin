#!/usr/bin/python3 -I
"""Stands in for aapt2 during a local Bazel build: runs the real aapt2 next to it and records the
invocation, its input files and the outputs, so the invocation can be replayed with other aapt2s.

$CAPTURE/cas/<sha256>            file contents
$CAPTURE/runs/<id>.json          argv, cwd, {path: sha256} of inputs and outputs, exit code
Files under external/ (the SDK's android.jar) are recorded by path only.

Install it as build-tools/<version>/aapt2 in a copy of the SDK, with the real binary next to it as
aapt2.real, and point Bazel at that copy with --override_repository.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

REAL = os.path.join(os.path.dirname(os.path.realpath(__file__)), "aapt2.real")
CAPTURE = "/tmp/aapt2-capture"

IN_OPTS = {"--manifest", "-I", "-R", "-A", "--stable-ids", "--resources-config-path",
           "--feature-flags-file", "--config", "--exclude-sources"}
OUT_OPTS = {"-o", "--java", "--output-text-symbols", "--proguard", "--proguard-main-dex", "--emit-ids",
            "--output-to-dir", "--resources-config-path-out"}
OTHER_VALUE_OPTS = {"--custom-package", "--package-id", "--preferred-density", "-c", "-0",
                    "--min-sdk-version", "--target-sdk-version", "--version-code", "--version-name",
                    "--feature-flags", "--rename-manifest-package", "--target-densities",
                    "--output-format", "-x", "--split", "--private-symbols", "--add-javadoc-annotation",
                    "--extra-packages", "--rename-resources-package", "--compile-sdk-version-code",
                    "--compile-sdk-version-name", "--product", "--filter", "--exclude-configs",
                    "--trace-folder", "--source-path"}


def store(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    digest = h.hexdigest()
    dst = os.path.join(CAPTURE, "cas", digest)
    if not os.path.exists(dst):
        tmp = f"{dst}.{os.getpid()}.tmp"
        shutil.copyfile(path, tmp)
        os.replace(tmp, dst)
    return digest


def record(path, into):
    ap = os.path.abspath(path)
    rel = os.path.relpath(ap, os.getcwd())
    if rel.startswith("external/"):
        into[ap] = "external:" + rel
        return
    if os.path.isdir(ap):
        for root, _, files in os.walk(ap):
            for name in files:
                p = os.path.join(root, name)
                into[p] = store(p)
    elif os.path.isfile(ap):
        into[ap] = store(ap)


def paths_in_args(args):
    inputs, outputs = [], []
    i = 1
    while i < len(args):
        a = args[i]
        if a in IN_OPTS | OUT_OPTS | OTHER_VALUE_OPTS and i + 1 < len(args):
            v = args[i + 1]
            if a in IN_OPTS:
                if v.startswith("@"):
                    inputs.append(v[1:])
                    inputs += open(v[1:]).read().split()
                else:
                    inputs.append(v)
            elif a in OUT_OPTS:
                outputs.append(v)
            i += 2
            continue
        if a.startswith("@") and os.path.isfile(a[1:]):
            inputs.append(a[1:])
            inputs += [t for t in open(a[1:]).read().split() if os.path.exists(t)]
        elif not a.startswith("-") and os.path.exists(a):
            inputs.append(a)
        i += 1
    return inputs, outputs


def main():
    args = sys.argv[1:]
    os.makedirs(os.path.join(CAPTURE, "cas"), exist_ok=True)
    os.makedirs(os.path.join(CAPTURE, "runs"), exist_ok=True)
    inputs, outputs = paths_in_args(args) if args else ([], [])
    ins = {}
    for p in inputs:
        record(p, ins)
    before = {}
    for p in outputs:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for name in files:
                    q = os.path.join(root, name)
                    before[os.path.abspath(q)] = os.stat(q).st_mtime_ns
    r = subprocess.run([REAL] + args)
    outs = {}
    for p in outputs:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for name in files:
                    q = os.path.abspath(os.path.join(root, name))
                    if before.get(q) != os.stat(q).st_mtime_ns:
                        outs[q] = store(q)
        else:
            record(p, outs)
    run = {"argv": args, "cwd": os.getcwd(), "inputs": ins, "outputs": outs,
           "output_args": [os.path.abspath(p) for p in outputs], "exit": r.returncode}
    rid = f"{time.time_ns()}-{os.getpid()}"
    with open(os.path.join(CAPTURE, "runs", rid + ".json"), "w") as f:
        json.dump(run, f)
    sys.exit(r.returncode)


if __name__ == "__main__":
    main()
