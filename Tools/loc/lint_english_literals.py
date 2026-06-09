#!/usr/bin/env python3
"""Fail if any localization call-site still uses a non-dotted-key literal."""
import re, sys
from pathlib import Path

SOURCES = Path("Packages/ArrCore/Sources/ArrCore")
CALL_RE = re.compile(
    r'(?:Text\(\s*|String\(\s*localized:\s*|Label\(\s*|NSLocalizedString\(\s*)"((?:[^"\\]|\\.)*)"')
DOTTED_RE = re.compile(r'^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*){1,2}$')

def offending_literals(src):
    bad = []
    for m in CALL_RE.finditer(src):
        lit = m.group(1)
        if lit == "" or lit.startswith("\\("):  # pure interpolation
            continue
        if not DOTTED_RE.match(lit):
            bad.append(lit)
    return bad

def main():
    failures = []
    for path in SOURCES.rglob("*.swift"):
        bad = offending_literals(path.read_text())
        for lit in bad:
            failures.append(f"{path}: {lit!r}")
    for f in failures:
        print("LINT:", f)
    print(f"{len(failures)} offending literals")
    sys.exit(0 if not failures else 1)

if __name__ == "__main__":
    main()
