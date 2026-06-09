#!/usr/bin/env python3
"""Add hardcoded English literals that were never in the catalog.

These are localization-call literals the migration left untouched because they
had no catalog key. We append a dotted key for each (plain literals only — skip
interpolated `\\(...)` ones and pure punctuation), into BOTH mapping.json and the
current (already dotted) catalog. Then migrate_code.py picks them up by oldKey.
"""
import json
from pathlib import Path
from build_mapping import slug, infer_role
from refine_mapping import FILE_AREA, ROLE_LABEL
from lint_english_literals import offending_literals, SOURCES

CATALOG = Path("Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings")
MAPPING = Path("Tools/loc/mapping.json")
SKIP = {"·"}  # pure punctuation -> handled as Text(verbatim:) in code, not localized

def collect():
    """Return dict literal -> file stem (first occurrence), plain literals only."""
    found = {}
    for p in sorted(SOURCES.rglob("*.swift")):
        for lit in offending_literals(p.read_text()):
            if "\\(" in lit or lit in SKIP:
                continue
            found.setdefault(lit, p.stem)
    return found

def main():
    recs = json.loads(MAPPING.read_text())
    existing_keys = {r["newKey"] for r in recs}
    cat = json.loads(CATALOG.read_text())
    strings = cat["strings"]

    added = 0
    for lit, stem in collect().items():
        if any(r["oldKey"] == lit for r in recs):
            continue  # already mapped
        area = FILE_AREA.get(stem, "common")
        role = infer_role(lit)
        key = f"{area}.{slug(lit)}.{role}"
        n = 2
        while key in existing_keys:
            key = f"{area}.{slug(lit)}{n}.{role}"
            n += 1
        existing_keys.add(key)
        comment = f"{ROLE_LABEL.get(role, 'Label')} in {area}"
        recs.append({"oldKey": lit, "newKey": key, "en": lit, "comment": comment,
                     "area": area, "role": role, "usages": [stem], "needsReview": False})
        strings[key] = {"extractionState": "manual", "comment": comment,
                        "localizations": {"en": {"stringUnit": {"state": "translated",
                                                                "value": lit}}}}
        added += 1
        print(f"  + {key}  <-  {lit!r}")

    MAPPING.write_text(json.dumps(recs, ensure_ascii=False, indent=2))
    CATALOG.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + "\n")
    print(f"added {added} keys to mapping.json and catalog")

if __name__ == "__main__":
    main()
