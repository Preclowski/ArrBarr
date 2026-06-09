#!/usr/bin/env python3
"""Validate a finalized mapping.json before applying it."""
import json, re, sys, argparse
from pathlib import Path

KEY_RE = re.compile(r"^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*){1,2}$")

def validate(records):
    errs = []
    seen = {}
    for r in records:
        nk = r.get("newKey", "")
        ok = r.get("oldKey", "")
        if nk == "":
            errs.append(f"empty newKey for oldKey={ok!r}")
            continue
        if not KEY_RE.match(nk):
            errs.append(f"bad key format: {nk!r} (oldKey={ok!r})")
        if nk in seen:
            errs.append(f"duplicate newKey {nk!r} (oldKey={ok!r} and {seen[nk]!r})")
        seen[nk] = ok
    return errs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mapping", default="Tools/loc/mapping.json")
    args = ap.parse_args()
    recs = json.loads(Path(args.mapping).read_text())
    errs = validate(recs)
    for e in errs:
        print("ERROR:", e)
    print(f"{len(recs)} records, {len(errs)} errors")
    sys.exit(0 if not errs else 1)

if __name__ == "__main__":
    main()
