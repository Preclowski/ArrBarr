#!/usr/bin/env python3
"""English templates of the messages the arrs hard-code, and our translations of them.

The arrs don't localise rejections or queue status messages: they are C# literals, absent from
their Localization/Core/*.json. Clone the sources elsewhere (never into this repo: they are GPL):

    git clone --depth 1 --filter=blob:none --sparse https://github.com/Radarr/Radarr.git
    git -C Radarr sparse-checkout set src/NzbDrone.Core

    python3 -I Tools/loc/arr_messages.py extract <dirs holding Radarr*, Sonarr*, Lidarr*, Whisparr*>
    python3 -I Tools/loc/arr_messages.py generate

Clone the stable branch next to develop: released versions phrase some messages differently.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Tools/loc/arr_messages.json"
CATALOG = ROOT / "Packages/ArrCore/Sources/ArrCore/Resources/ArrMessages.xcstrings"
TEMPLATES = ROOT / "Packages/ArrCore/Sources/ArrCore/Services/ArrMessageTemplates.swift"
ARRS = ("Radarr", "Sonarr", "Lidarr", "Whisparr")
LANGUAGES = ("de", "es", "fr", "nl", "pl")

# Only what reaches `rejections` and `statusMessages`.
SITES = re.compile(
    r"(?:(?:DownloadSpec|ImportSpec)?Decision\.Reject\(\s*(?:\w+\.\w+,\s*)?"
    r"|new (?:Import)?Rejection\(\s*(?:\w+\.\w+,\s*)?"
    r"|RejectionResult\(\s*(?:\w+\.\w+,\s*)?"
    r"|new ImportResult\(\s*\w+,\s*"
    r"|new TrackedDownloadStatusMessage\(\s*"
    r"|[tT]rackedDownload\.Warn\(\s*)"
    r'(\$@|@\$|\$|@)?"'
)
PLACEHOLDER = re.compile(r"\{[^{}]+\}")
MIN_LITERAL = 8
# Reach the app but aren't in the checkouts: older releases, the demo fixtures, the API layer.
EXTRA = (
    "Not an upgrade for existing episode file(s)",
    "Not an upgrade for existing movie file",
    "Not an upgrade for existing movie file(s)",
    "Quality profile does not allow %@",
    "Couldn't find requested release in cache, try searching again",
)
# The arrs fill this `{0}` with English words, so a placeholder would leave them untranslated.
HISTORY_SUBJECT = "%@ grab event in history"
HISTORY_SUBJECTS = ("Recent grab event in history", "CDH is disabled and grab event in history")


def literal_body(source, start, interpolated):
    """A scan, not a regex: an interpolated hole can hold quotes of its own (`{string.Join(", ", x)}`)."""
    depth = 0
    position = start
    while position < len(source):
        character = source[position]
        if character == "\\":
            position += 2
            continue
        if interpolated and character == "{":
            depth += 1
        elif interpolated and character == "}":
            depth -= 1
        elif character == '"' and depth == 0:
            return source[start:position]
        position += 1
    return ""


def template_from(prefix, body):
    """`{0}` and `{name}` become `%@`, so the key reads like every other format string."""
    prefix = prefix or ""
    if "@" not in prefix:
        body = body.replace('\\"', '"').replace("\\\\", "\\").replace("\\n", "\n")
    return PLACEHOLDER.sub("%@", body.replace("%", "%%")).strip()


def extract(source_roots):
    found = {template: set() for template in EXTRA}
    for arr in ARRS:
        for checkout in (c for root in source_roots for c in Path(root).glob(arr + "*")):
            for path in (checkout / "src/NzbDrone.Core").rglob("*.cs"):
                source = path.read_text(encoding="utf-8", errors="replace")
                for match in SITES.finditer(source):
                    prefix = match.group(1)
                    body = literal_body(source, match.end(), interpolated="$" in (prefix or ""))
                    template = template_from(prefix, body)
                    if len(template.replace("%@", "").strip()) < MIN_LITERAL:
                        continue
                    variants = (
                        [template.replace(HISTORY_SUBJECT, subject, 1) for subject in HISTORY_SUBJECTS]
                        if template.startswith(HISTORY_SUBJECT)
                        else [template]
                    )
                    for variant in variants:
                        found.setdefault(variant, set()).add(arr)

    known = json.loads(DATA.read_text(encoding="utf-8")) if DATA.exists() else {}
    merged = {
        template: {"arrs": sorted(arrs), **{k: v for k, v in known.get(template, {}).items() if k != "arrs"}}
        for template, arrs in sorted(found.items())
    }
    DATA.write_text(json.dumps(merged, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    dropped = sorted(set(known) - set(merged))
    print(f"{len(merged)} templates, {len(dropped)} dropped from the sources")
    report_missing(merged)


def report_missing(data):
    missing = [t for t, entry in data.items() if any(language not in entry for language in LANGUAGES)]
    print(f"{len(missing)} without every translation")


def specifiers(text):
    return len(re.findall(r"%(?:\d+\$)?@", text))


def generate():
    data = json.loads(DATA.read_text(encoding="utf-8"))
    report_missing(data)
    strings = {}
    for template, entry in data.items():
        for language in LANGUAGES:
            if language in entry and specifiers(entry[language]) != specifiers(template):
                sys.exit(f"{language}: placeholders differ from {template!r}")
        localizations = {"en": {"stringUnit": {"state": "translated", "value": template}}}
        for language in LANGUAGES:
            if language in entry:
                localizations[language] = {"stringUnit": {"state": "translated", "value": entry[language]}}
        # No symbols: nothing reads them, and "Wrong Episode" and "Wrong episode" would collide.
        strings[template] = {"extractionState": "manual", "generatesSymbol": False, "localizations": localizations}
    CATALOG.write_text(
        json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    lines = ",\n".join("        " + json.dumps(t, ensure_ascii=False) for t in data)
    TEMPLATES.write_text(
        "// Generated by Tools/loc/arr_messages.py.\n\n"
        "nonisolated enum ArrMessageTemplates {\n"
        "    static let all: [String] = [\n" + lines + "\n    ]\n}\n",
        encoding="utf-8",
    )
    print(f"{len(data)} templates written")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "extract" and len(sys.argv) >= 3:
        extract(sys.argv[2:])
    elif command == "generate":
        generate()
    else:
        sys.exit(__doc__)
