#!/usr/bin/env python3
"""Rewrite the catalog with dotted keys: EN materialized + comment, selected langs carried."""
import json, argparse
from pathlib import Path

CATALOG = Path("Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings")

def rebuild(old_catalog, mapping, keep_langs=("pl",)):
    old_strings = old_catalog["strings"]
    new_strings = {}
    for rec in mapping:
        old_key, new_key = rec["oldKey"], rec["newKey"]
        en_value = rec["en"]
        entry = {"extractionState": "manual",
                 "localizations": {
                     "en": {"stringUnit": {"state": "translated", "value": en_value}}}}
        if rec.get("comment"):
            entry["comment"] = rec["comment"]
        old_locs = old_strings.get(old_key, {}).get("localizations", {})
        for lang in keep_langs:
            unit = old_locs.get(lang)
            if unit and unit.get("stringUnit", {}).get("value"):
                entry["localizations"][lang] = {
                    "stringUnit": {"state": "translated",
                                   "value": unit["stringUnit"]["value"]}}
        new_strings[new_key] = entry
    return {"sourceLanguage": "en", "version": "1.1", "strings": new_strings}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mapping", default="Tools/loc/mapping.json")
    ap.add_argument("--keep", default="pl")
    args = ap.parse_args()
    old = json.loads(CATALOG.read_text())
    mapping = json.loads(Path(args.mapping).read_text())
    new = rebuild(old, mapping, keep_langs=args.keep.split(","))
    CATALOG.write_text(json.dumps(new, ensure_ascii=False, indent=2) + "\n")
    print(f"rewrote catalog: {len(new['strings'])} keys")

if __name__ == "__main__":
    main()
