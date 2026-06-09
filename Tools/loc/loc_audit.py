#!/usr/bin/env python3
"""Audit a Localizable.xcstrings catalog for empty/missing/new strings."""
import json, sys, argparse
from pathlib import Path

DEFAULT_LANGS = ["en", "pl", "de", "es", "fr", "nl"]

def audit(catalog, languages=DEFAULT_LANGS):
    strings = catalog.get("strings", {})
    report = {
        "total_keys": len(strings),
        "empty_keys": [],
        "empty_values": [],
        "new_state": [],
        "missing": [],
        "languages": languages,
    }
    for key, entry in strings.items():
        if key == "":
            report["empty_keys"].append(key)
            continue
        locs = entry.get("localizations", {})
        for lang in languages:
            unit = locs.get(lang)
            if unit is None:
                report["missing"].append((key, lang))
                continue
            su = unit.get("stringUnit")
            if su is None:
                continue
            state = su.get("state", "")
            value = su.get("value", "")
            if value == "":
                report["empty_values"].append((key, lang))
            if state in ("new", "needs_review"):
                report["new_state"].append((key, lang))
    return report

def is_clean(report):
    return not (report["empty_keys"] or report["empty_values"]
                or report["new_state"] or report["missing"])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog")
    ap.add_argument("--langs", default=",".join(DEFAULT_LANGS))
    args = ap.parse_args()
    cat = json.loads(Path(args.catalog).read_text())
    rep = audit(cat, args.langs.split(","))
    for k in ("empty_keys", "empty_values", "new_state", "missing"):
        print(f"{k}: {len(rep[k])}")
        for item in rep[k][:40]:
            print("   ", item)
    print(f"total_keys: {rep['total_keys']}")
    sys.exit(0 if is_clean(rep) else 1)

if __name__ == "__main__":
    main()
