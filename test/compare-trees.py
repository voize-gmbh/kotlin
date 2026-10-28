#!/usr/bin/env python3
"""Compare output trees file by file. usage: compare-trees.py <reference dir> <dir>..."""
import collections
import hashlib
import os
import sys


def tree(root):
    out = {}
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            h = hashlib.sha256(open(p, "rb").read()).hexdigest()
            out[os.path.relpath(p, root)] = h
    return out


ref_root = sys.argv[1]
ref = tree(ref_root)
kinds = collections.Counter(p.split("/")[0] if "/" in p else "(top)" for p in ref)
print(f"reference {ref_root}: {len(ref)} files", dict(kinds))
status = 0
for other_root in sys.argv[2:]:
    other = tree(other_root)
    missing = sorted(set(ref) - set(other))
    extra = sorted(set(other) - set(ref))
    differ = sorted(p for p in set(ref) & set(other) if ref[p] != other[p])
    same = len(set(ref) & set(other)) - len(differ)
    print(f"\n{other_root}: {len(other)} files, identical {same}, differ {len(differ)}, "
          f"missing {len(missing)}, extra {len(extra)}")
    for label, items in (("differ", differ), ("missing", missing), ("extra", extra)):
        for p in items[:40]:
            print(f"  {label}: {p}")
    if differ or missing or extra:
        status = 1
sys.exit(status)
