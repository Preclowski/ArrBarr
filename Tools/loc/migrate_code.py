#!/usr/bin/env python3
"""Rewrite localization call-site literals from English text to dotted keys."""
import json, re, argparse
from pathlib import Path

SOURCES = Path("Packages/ArrCore/Sources/ArrCore")

CALL_RE = re.compile(
    r'(Text\(\s*|String\(\s*localized:\s*|Label\(\s*|NSLocalizedString\(\s*)"((?:[^"\\]|\\.)*)"')

def _unescape(s):
    # Swift uses \u{XXXX} but Python's unicode_escape expects \uXXXX.
    # Since mapping keys are plain ASCII, we only need basic unescaping;
    # for any literal we can't decode, return it as-is (it won't match any key).
    try:
        # Convert Swift \u{XXXX} → \uXXXX first
        s2 = re.sub(r'\\u\{([0-9a-fA-F]+)\}', lambda m: '\\u{:04x}'.format(int(m.group(1), 16)), s)
        return s2.encode().decode("unicode_escape")
    except (UnicodeDecodeError, ValueError):
        return s

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
