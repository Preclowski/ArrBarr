#!/usr/bin/env python3
"""Fail if code references a localization key (by catalog area prefix) that is
not in the catalog. Catches the 'raw dotted key leaks to the UI' class of bug
that the call-site lint misses — e.g. keys passed as LocalizedStringKey via a
variable, which migrate_code never rewrites. Area prefixes come from the catalog
itself, so SF Symbol names (arrow.*, chevron.*) and RPC ids are ignored.
"""
import re, json, sys
from pathlib import Path

SOURCES = Path("Packages/ArrCore/Sources/ArrCore")
CATALOG = SOURCES / "Resources/Localizable.xcstrings"

def catalog_keys_and_areas():
    keys = set(json.loads(CATALOG.read_text())["strings"])
    areas = {k.split(".", 1)[0] for k in keys if "." in k}
    return keys, areas

def missing_keys(sources=SOURCES):
    keys, areas = catalog_keys_and_areas()
    # any string literal shaped like a dotted key whose first segment is a
    # known catalog area
    lit = re.compile(r'"([a-z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9]+){1,6})"')
    bad = {}
    for p in sources.rglob("*.swift"):
        for m in lit.finditer(p.read_text()):
            k = m.group(1)
            if k.split(".", 1)[0] in areas and k not in keys:
                bad.setdefault(k, p.name)
    return bad

def main():
    bad = missing_keys()
    for k, f in sorted(bad.items()):
        print(f"MISSING-KEY: {k}  ({f})")
    print(f"{len(bad)} code-referenced keys missing from catalog")
    sys.exit(0 if not bad else 1)

if __name__ == "__main__":
    main()
