#!/usr/bin/env python3
"""Rewrite localization call-site literals from English text to dotted keys."""
import json, re, argparse
from pathlib import Path

SOURCES = Path("Packages/ArrCore/Sources/ArrCore")

CALL_RE = re.compile(
    r'(Text\(\s*|String\(\s*localized:\s*|Label\(\s*|NSLocalizedString\(\s*)"((?:[^"\\]|\\.)*)"')

def _unescape(s):
    # Only undo the escapes Swift string literals actually use for our keys:
    # \" -> " and \\ -> \. Do NOT use unicode_escape — it corrupts non-ASCII
    # bytes (…, —, smart quotes) and breaks matching against UTF-8 catalog keys.
    return s.replace('\\"', '"').replace('\\\\', '\\')

def _escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')

def migrate_text(src, mapping):
    def repl(m):
        prefix, literal = m.group(1), m.group(2)
        key = _unescape(literal)
        new = mapping.get(key)
        return f'{prefix}"{_escape(new)}"' if new else m.group(0)
    return CALL_RE.sub(repl, src)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mapping", default="Tools/loc/mapping.json")
    args = ap.parse_args()
    recs = json.loads(Path(args.mapping).read_text())
    mapping = {r["oldKey"]: r["newKey"] for r in recs}
    changed = 0
    for path in SOURCES.rglob("*.swift"):
        text = path.read_text()
        new = migrate_text(text, mapping)
        if new != text:
            path.write_text(new)
            changed += 1
    print(f"migrated {changed} files")

if __name__ == "__main__":
    main()
