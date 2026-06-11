# Localization Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `Localizable.xcstrings` to semantic dotted keys with a clean canonical English source, a hand-audited Polish reference, freshly regenerated de/es/fr translations, a new Dutch (nl) language, and correct CLDR plurals — with zero empty or missing strings.

**Architecture:** Tooling-driven, semi-automated migration. Python scripts in `Tools/loc/` do the mechanical heavy lifting (audit, mapping generation, catalog rewrite, code call-site migration, lint); humans/agents make the naming and translation judgment calls. Scripts are built TDD-first against fixtures. Content phases (PL audit, translations) are gated by the audit script reporting zero issues plus a successful build + visual relaunch.

**Tech Stack:** Python 3.14 (stdlib only — `json`, `re`, `pathlib`, `argparse`), Swift 6 / SwiftUI (xcstrings catalog), `xcodebuild`, SwiftPM `swift test`.

**Spec:** `docs/superpowers/specs/2026-06-09-localization-overhaul-design.md`

---

## Conventions used throughout

- **Catalog:** `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`
- **Sources root:** `Packages/ArrCore/Sources/ArrCore`
- **Tooling:** `Tools/loc/` (new dir). Run scripts from repo root.
- **Languages:** `en` (canonical source), `pl` (reference), `de`, `es`, `fr`, `nl` (regenerated/new).
- **Key scheme:** `area.component.role` camelCase (e.g. `queue.pauseAll.button`).
- **Branch:** `localization-overhaul` (already created).
- **Plans/specs dir is gitignored** — do not try to `git add` files under `docs/superpowers/`.

## File Structure

**New (tooling — committed):**
- `Tools/loc/loc_audit.py` — catalog sanity checker (counts, empty/missing/`new`, per-language coverage).
- `Tools/loc/build_mapping.py` — emits draft `Tools/loc/mapping.json` (old key → suggested dotted key + context + usage sites + EN value).
- `Tools/loc/apply_mapping.py` — consumes finalized `mapping.json` → rewrites the catalog with dotted keys.
- `Tools/loc/migrate_code.py` — rewrites Swift call-sites from English literals to dotted keys via `mapping.json`.
- `Tools/loc/lint_english_literals.py` — fails if any localization call-site still uses an English literal instead of a dotted key.
- `Tools/loc/glossary.md` — terminology table (PL + per-language equivalents). Authored in Phase/Task 7.
- `Tools/loc/tests/` — pytest-free, stdlib `unittest` tests + tiny xcstrings fixtures.

**Modified:**
- `Localizable.xcstrings` (rewritten).
- ~66 `.swift` files under `Packages/ArrCore/Sources/ArrCore` (call-site migration).
- `Packages/ArrCore/Sources/ArrCore/Services/ChatToolCatalog.swift` (Polish-literal-key origin, if found there).

---

## Task 1: Catalog audit tool (sanity checker)

This is the verification backbone reused in Tasks 6 and 10. Build it first, TDD.

**Files:**
- Create: `Tools/loc/loc_audit.py`
- Create: `Tools/loc/tests/test_loc_audit.py`
- Create: `Tools/loc/tests/fixtures/sample.xcstrings`

- [ ] **Step 1: Write the fixture**

Create `Tools/loc/tests/fixtures/sample.xcstrings`:

```json
{
  "sourceLanguage" : "en",
  "version" : "1.1",
  "strings" : {
    "" : {},
    "queue.pauseAll.button" : {
      "comment" : "Button: pause every download",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Pause all" } },
        "pl" : { "stringUnit" : { "state" : "translated", "value" : "Wstrzymaj wszystko" } },
        "de" : { "stringUnit" : { "state" : "translated", "value" : "" } }
      }
    },
    "discover.noMoreCards.title" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "new", "value" : "No more cards" } }
      }
    }
  }
}
```

- [ ] **Step 2: Write the failing test**

Create `Tools/loc/tests/test_loc_audit.py`:

```python
import json, unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loc_audit import audit

FIX = Path(__file__).parent / "fixtures" / "sample.xcstrings"

class TestAudit(unittest.TestCase):
    def setUp(self):
        self.report = audit(json.loads(FIX.read_text()),
                            languages=["en", "pl", "de", "es", "fr", "nl"])

    def test_detects_empty_key(self):
        self.assertIn("", self.report["empty_keys"])

    def test_detects_empty_value(self):
        # de value for queue.pauseAll.button is ""
        self.assertIn(("queue.pauseAll.button", "de"), self.report["empty_values"])

    def test_detects_new_state(self):
        self.assertIn(("discover.noMoreCards.title", "en"), self.report["new_state"])

    def test_detects_missing(self):
        # discover.noMoreCards.title missing pl/de/es/fr/nl
        self.assertIn(("discover.noMoreCards.title", "pl"), self.report["missing"])

    def test_total_keys_excludes_nothing(self):
        self.assertEqual(self.report["total_keys"], 3)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run test to verify it fails**

Run: `python3 -m unittest Tools.loc.tests.test_loc_audit -v` (from repo root)
Expected: FAIL — `ModuleNotFoundError: No module named 'loc_audit'`

- [ ] **Step 4: Implement `loc_audit.py`**

Create `Tools/loc/loc_audit.py`:

```python
#!/usr/bin/env python3
"""Audit a Localizable.xcstrings catalog for empty/missing/new strings."""
import json, sys, argparse
from pathlib import Path

DEFAULT_LANGS = ["en", "pl", "de", "es", "fr", "nl"]

def audit(catalog, languages=DEFAULT_LANGS):
    strings = catalog.get("strings", {})
    report = {
        "total_keys": len(strings),
        "empty_keys": [],      # keys that are the empty string
        "empty_values": [],    # (key, lang) with "" value
        "new_state": [],       # (key, lang) in state new/needs_review
        "missing": [],         # (key, lang) language absent
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
                # English is allowed to be implicit only in source-string-as-key
                # catalogs; after migration every key must carry every language.
                report["missing"].append((key, lang))
                continue
            su = unit.get("stringUnit")
            if su is None:
                # variations (plural) — checked separately, skip here
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `python3 -m unittest Tools.loc.tests.test_loc_audit -v`
Expected: PASS (5 tests)

- [ ] **Step 6: Sanity-run against the real catalog**

Run: `python3 Tools/loc/loc_audit.py Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`
Expected: non-zero exit; reports empty_keys: 1, plus missing/new counts (baseline of current mess).

- [ ] **Step 7: Commit**

```bash
git add Tools/loc/loc_audit.py Tools/loc/tests/
git commit -m "feat(loc): catalog audit tool"
```

---

## Task 2: Mapping generator (draft old→dotted keys)

Produces a reviewable draft. Naming is finalized by a human in Task 3.

**Files:**
- Create: `Tools/loc/build_mapping.py`
- Create: `Tools/loc/tests/test_build_mapping.py`

- [ ] **Step 1: Write the failing test**

Create `Tools/loc/tests/test_build_mapping.py`:

```python
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_mapping import slug, infer_role, suggest_key

class TestMapping(unittest.TestCase):
    def test_slug_camelcases_first_words(self):
        self.assertEqual(slug("Pause all downloads"), "pauseAllDownloads")

    def test_slug_truncates_long_text(self):
        s = slug("This is a very long sentence that should be truncated cleanly")
        self.assertLessEqual(s.count(" "), 0)
        self.assertTrue(len(s) <= 40)

    def test_infer_role_tooltip_for_sentence(self):
        self.assertEqual(infer_role("Pauses every active download."), "tooltip")

    def test_infer_role_button_for_short_imperative(self):
        self.assertEqual(infer_role("Pause all"), "button")

    def test_suggest_key_uses_area(self):
        self.assertTrue(suggest_key("queue", "Pause all").startswith("queue."))

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest Tools.loc.tests.test_build_mapping -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'build_mapping'`

- [ ] **Step 3: Implement `build_mapping.py`**

Create `Tools/loc/build_mapping.py`:

```python
#!/usr/bin/env python3
"""Generate a draft old-key -> dotted-key mapping for review.

Writes Tools/loc/mapping.json: a list of records, each:
  {oldKey, newKey, en, comment, area, role, usages, needsReview}
Run, then hand-edit newKey/comment/area/role before apply_mapping.py.
"""
import json, re, subprocess, argparse
from pathlib import Path

SOURCES = Path("Packages/ArrCore/Sources/ArrCore")
CATALOG = SOURCES / "Resources/Localizable.xcstrings"

# Map a Swift filename (no extension) -> catalog area.
FILE_AREA = {
    "QueueGroupRowView": "queue", "QueueRowView": "queue", "QueueListView": "queue",
    "QueueSectionView": "queue", "QueueTabContent": "queue", "DownloadSection": "queue",
    "QueueSearchResultsView": "queue", "QueueComparisonCard": "queue",
    "PauseResumeButton": "queue", "DownloadProgressCard": "queue",
    "SettingsView": "settings", "ICloudSettingsView": "settings",
    "MCPSettingsPane": "settings", "ServiceFields": "settings",
    "SiriShortcutsSettings": "settings", "ApiKeyTestButton": "settings",
    "ChatView": "chat", "ChatTabContent": "chat", "ChatEmptyStateView": "chat",
    "ChatUnavailableView": "chat", "MarkdownMessage": "chat", "RichToolResultView": "chat",
    "SuggestionPromptRow": "chat", "ShimmerThinkingLabel": "chat",
    "DiscoverTabView": "discover", "DiscoverCardView": "discover",
    "DiscoverMatchedListView": "discover", "QuizFeatureCard": "discover",
    "QuizResumeCard": "discover",
    "SearchView": "search", "SearchAddPanel": "search", "SearchResultRow": "search",
    "QueueSearchRow": "search",
    "DetailView": "detail", "DetailViewHelpers": "detail", "MediaHeaderCard": "detail",
    "EpisodeDetailOverlay": "detail", "EpisodeQuickDetail": "detail", "CastRow": "detail",
    "SonarrDetailPanel": "detail", "RadarrDetailPanel": "detail",
    "LidarrDetailPanel": "detail", "SeasonRow": "detail", "TrackRow": "detail",
    "EpisodeRow": "detail", "ExpandableOverview": "detail", "PosterMetadataRow": "detail",
    "UpcomingRowView": "upcoming", "UpcomingTabContent": "upcoming",
    "HistoryView": "history",
    "WelcomeView": "onboarding", "QuizFeatureCard": "onboarding",
    "PaywallView": "paywall", "PaywallHeroes": "paywall",
    "NeedsYouSectionView": "queue", "PopoverEmptyState": "common",
    "ConfirmActionCard": "common", "InlineConfirm": "common",
    "ExistingFileBanner": "common", "LoadErrorLine": "common",
}

def slug(text, max_words=4):
    words = re.findall(r"[A-Za-z0-9]+", text)[:max_words]
    if not words:
        return "untitled"
    out = words[0].lower() + "".join(w.capitalize() for w in words[1:])
    return out[:40]

def infer_role(text):
    t = text.strip()
    if t.endswith((".", "!", "?")) or len(t) > 40:
        return "tooltip"
    if "%@" in t or "%lld" in t:
        return "label"
    if t.istitle() or (t[:1].isupper() and " " in t and len(t) <= 24):
        return "button"
    return "label"

def suggest_key(area, text):
    return f"{area}.{slug(text)}.{infer_role(text)}"

def grep_usages(literal):
    """Return list of files referencing this literal (best-effort)."""
    esc = literal.replace("\\", "\\\\").replace('"', '\\"')
    if esc == "" or len(esc) > 200:
        return []
    try:
        out = subprocess.run(
            ["grep", "-rl", "--include=*.swift", "-F", f'"{esc}"', str(SOURCES)],
            capture_output=True, text=True, timeout=30)
        return [Path(p).stem for p in out.stdout.splitlines()]
    except Exception:
        return []

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="Tools/loc/mapping.json")
    args = ap.parse_args()
    cat = json.loads(CATALOG.read_text())
    records = []
    for old_key, entry in cat["strings"].items():
        if old_key == "":
            continue  # dropped
        en_unit = entry.get("localizations", {}).get("en", {}).get("stringUnit", {})
        en_value = en_unit.get("value", old_key)  # source-string-as-key fallback
        files = grep_usages(old_key)
        area = next((FILE_AREA[f] for f in files if f in FILE_AREA), "common")
        records.append({
            "oldKey": old_key,
            "newKey": suggest_key(area, en_value),
            "en": en_value,
            "comment": "",
            "area": area,
            "role": infer_role(en_value),
            "usages": files,
            "needsReview": area == "common" or not files,
        })
    Path(args.out).write_text(json.dumps(records, ensure_ascii=False, indent=2))
    flagged = sum(1 for r in records if r["needsReview"])
    print(f"wrote {len(records)} records to {args.out} ({flagged} need review)")

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest Tools.loc.tests.test_build_mapping -v`
Expected: PASS (5 tests)

- [ ] **Step 5: Generate the draft mapping**

Run: `python3 Tools/loc/build_mapping.py`
Expected: `wrote ~630 records to Tools/loc/mapping.json (N need review)`

- [ ] **Step 6: Commit the tool (not the generated mapping yet)**

```bash
git add Tools/loc/build_mapping.py Tools/loc/tests/test_build_mapping.py
git commit -m "feat(loc): draft mapping generator"
```

---

## Task 3: Finalize the mapping (human/agent review)

This is a judgment task — no script. Acceptance is a clean, collision-free `mapping.json`.

**Files:**
- Modify: `Tools/loc/mapping.json`
- Create: `Tools/loc/check_mapping.py` (validates the finalized mapping)
- Create: `Tools/loc/tests/test_check_mapping.py`

- [ ] **Step 1: Write the validator's failing test**

Create `Tools/loc/tests/test_check_mapping.py`:

```python
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_mapping import validate

class TestCheck(unittest.TestCase):
    def test_flags_duplicate_new_keys(self):
        recs = [{"oldKey":"A","newKey":"queue.x.button","en":"A"},
                {"oldKey":"B","newKey":"queue.x.button","en":"B"}]
        errs = validate(recs)
        self.assertTrue(any("duplicate" in e for e in errs))

    def test_flags_bad_key_format(self):
        recs = [{"oldKey":"A","newKey":"Queue X","en":"A"}]
        errs = validate(recs)
        self.assertTrue(any("format" in e for e in errs))

    def test_flags_empty_new_key(self):
        recs = [{"oldKey":"A","newKey":"","en":"A"}]
        errs = validate(recs)
        self.assertTrue(any("empty" in e for e in errs))

    def test_clean_mapping_has_no_errors(self):
        recs = [{"oldKey":"A","newKey":"queue.pauseAll.button","en":"A"},
                {"oldKey":"B","newKey":"queue.resumeAll.button","en":"B"}]
        self.assertEqual(validate(recs), [])

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest Tools.loc.tests.test_check_mapping -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'check_mapping'`

- [ ] **Step 3: Implement `check_mapping.py`**

Create `Tools/loc/check_mapping.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest Tools.loc.tests.test_check_mapping -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Review and finalize `mapping.json` (manual)**

For every record (work area-by-area to keep terminology consistent):
- Fix `newKey` to the right `area.component.role`. Resolve all `needsReview: true` rows.
- Write a `comment` describing the UI context (e.g. `"Tooltip on the pause-all toolbar button"`).
- For the 13 `new`-state Discover strings, confirm the English wording is final.
- For the Polish-literal source string (`oldKey == "Try: pokaż mi quiz na sobotę wieczór"`),
  set `newKey = "discover.tryExample.saturdayNight"` and `en = "Try: surprise me with a Saturday-night quiz"`
  (a proper English source — the PL phrasing moves to the `pl` translation in Task 7).
- For plural-shaped keys (`%lld days/episodes/downloads/tracks/items/picked`), set keys under the
  `unit` area: `unit.days`, `unit.episodes`, `unit.downloads`, `unit.tracks`, `unit.itemsNamed`
  (`%lld items: %@`), `discover.pickedCount` (`%lld picked`). Mark these `"plural": true` in the
  record so Task 8 can find them.

- [ ] **Step 6: Run the validator against the finalized mapping**

Run: `python3 Tools/loc/check_mapping.py`
Expected: `~630 records, 0 errors`

- [ ] **Step 7: Commit**

```bash
git add Tools/loc/check_mapping.py Tools/loc/tests/test_check_mapping.py Tools/loc/mapping.json
git commit -m "feat(loc): finalized key mapping + validator"
```

---

## Task 4: Rewrite the catalog to dotted keys (EN canon + PL carry-over)

**Files:**
- Create: `Tools/loc/apply_mapping.py`
- Create: `Tools/loc/tests/test_apply_mapping.py`
- Modify: `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`

- [ ] **Step 1: Write the failing test**

Create `Tools/loc/tests/test_apply_mapping.py`:

```python
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from apply_mapping import rebuild

class TestApply(unittest.TestCase):
    def setUp(self):
        self.old = {
            "sourceLanguage": "en", "version": "1.1",
            "strings": {
                "": {},
                "Pause all": {
                    "localizations": {
                        "pl": {"stringUnit": {"state": "translated", "value": "Wstrzymaj wszystko"}},
                        "de": {"stringUnit": {"state": "translated", "value": "Alle pausieren"}},
                    }
                },
            },
        }
        self.mapping = [
            {"oldKey": "Pause all", "newKey": "queue.pauseAll.button",
             "en": "Pause all", "comment": "Pause-all button"},
        ]
        self.new = rebuild(self.old, self.mapping, keep_langs=["pl"])

    def test_empty_key_dropped(self):
        self.assertNotIn("", self.new["strings"])

    def test_dotted_key_present(self):
        self.assertIn("queue.pauseAll.button", self.new["strings"])

    def test_en_materialized(self):
        unit = self.new["strings"]["queue.pauseAll.button"]["localizations"]["en"]["stringUnit"]
        self.assertEqual(unit["value"], "Pause all")
        self.assertEqual(unit["state"], "translated")

    def test_comment_written(self):
        self.assertEqual(self.new["strings"]["queue.pauseAll.button"]["comment"], "Pause-all button")

    def test_pl_carried_over(self):
        unit = self.new["strings"]["queue.pauseAll.button"]["localizations"]["pl"]["stringUnit"]
        self.assertEqual(unit["value"], "Wstrzymaj wszystko")

    def test_de_dropped(self):
        self.assertNotIn("de", self.new["strings"]["queue.pauseAll.button"]["localizations"])

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest Tools.loc.tests.test_apply_mapping -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'apply_mapping'`

- [ ] **Step 3: Implement `apply_mapping.py`**

Create `Tools/loc/apply_mapping.py`:

```python
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
        # carry selected languages from the old entry
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest Tools.loc.tests.test_apply_mapping -v`
Expected: PASS (6 tests)

- [ ] **Step 5: Apply to the real catalog**

Run: `python3 Tools/loc/apply_mapping.py`
Expected: `rewrote catalog: ~630 keys`

- [ ] **Step 6: Verify EN+PL are clean (de/es/fr/nl intentionally missing for now)**

Run: `python3 Tools/loc/loc_audit.py Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings --langs en,pl`
Expected: empty_keys: 0, empty_values: 0, new_state: 0, missing: 0 → exit 0.

- [ ] **Step 7: Commit**

```bash
git add Tools/loc/apply_mapping.py Tools/loc/tests/test_apply_mapping.py \
        Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "refactor(loc): rewrite catalog to semantic dotted keys (EN canon + PL)"
```

---

## Task 5: Migrate Swift call-sites to dotted keys

**Files:**
- Create: `Tools/loc/migrate_code.py`
- Create: `Tools/loc/tests/test_migrate_code.py`
- Modify: ~66 `.swift` files under `Packages/ArrCore/Sources/ArrCore`

- [ ] **Step 1: Write the failing test**

Create `Tools/loc/tests/test_migrate_code.py`:

```python
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from migrate_code import migrate_text

class TestMigrate(unittest.TestCase):
    def setUp(self):
        self.m = {"Pause all": "queue.pauseAll.button",
                  "Resume all": "queue.resumeAll.button"}

    def test_replaces_text_literal(self):
        src = 'Text("Pause all", bundle: .module)'
        self.assertEqual(migrate_text(src, self.m),
                         'Text("queue.pauseAll.button", bundle: .module)')

    def test_replaces_string_localized(self):
        src = 'String(localized: "Resume all", bundle: .module)'
        self.assertEqual(migrate_text(src, self.m),
                         'String(localized: "queue.resumeAll.button", bundle: .module)')

    def test_leaves_unrelated_strings(self):
        src = 'let id = "Pause all"  // not a localization call'
        self.assertEqual(migrate_text(src, self.m), src)

    def test_idempotent(self):
        once = migrate_text('Text("Pause all", bundle: .module)', self.m)
        twice = migrate_text(once, self.m)
        self.assertEqual(once, twice)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest Tools.loc.tests.test_migrate_code -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'migrate_code'`

- [ ] **Step 3: Implement `migrate_code.py`**

Create `Tools/loc/migrate_code.py`. Only rewrites literals that sit inside a known
localization call (`Text(`, `String(localized:`, `Label(`, `NSLocalizedString(`) on the same
line — so plain string constants are never touched.

```python
#!/usr/bin/env python3
"""Rewrite localization call-site literals from English text to dotted keys."""
import json, re, argparse
from pathlib import Path

SOURCES = Path("Packages/ArrCore/Sources/ArrCore")

# A localization call followed by a double-quoted literal we may replace.
CALL_RE = re.compile(
    r'(Text\(\s*|String\(\s*localized:\s*|Label\(\s*|NSLocalizedString\(\s*)"((?:[^"\\]|\\.)*)"')

def _unescape(s):
    return s.encode().decode("unicode_escape")

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
    mapping = {r["en"]: r["newKey"] for r in recs}
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest Tools.loc.tests.test_migrate_code -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Run the migration**

Run: `python3 Tools/loc/migrate_code.py`
Expected: `migrated ~60 files`

- [ ] **Step 6: Manually fix the 5 plural format-string call-sites**

These use `String(format: String(localized: "%lld …"), n)` — the inner literal is migrated to a
`unit.*` key by the regex, but confirm each compiles. Files:
- `Views/QueueGroupRowView.swift:218` (`%lld episodes` → `unit.episodes`)
- `Views/SettingsView.swift:1128` (`%lld days` → `unit.days`)
- `Views/DownloadSection.swift:268` (`%lld downloads` → `unit.downloads`)
- `Views/QuizResumeCard.swift:145` (`%lld picked` → `discover.pickedCount`)
- `Services/NotificationCoalescer.swift:269` (`%lld items: %@` → `unit.itemsNamed`)

Confirm each now reads e.g. `String(format: String(localized: "unit.episodes", bundle: .module), n)`.

- [ ] **Step 7: Investigate & fix the empty-key and Polish-literal origins**

Run: `grep -rn --include='*.swift' -e 'Text("")' -e 'Text(verbatim: "")' Packages/ArrCore/Sources`
and search for the old Polish example string usage. Replace any hardcoded empty `Text("")` with the
intended content or remove it; ensure the Discover example string now references
`discover.tryExample.saturdayNight`.

- [ ] **Step 8: Build**

Run: `xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add Tools/loc/migrate_code.py Tools/loc/tests/test_migrate_code.py Packages/ArrCore/Sources
git commit -m "refactor(loc): migrate call-sites to dotted keys"
```

---

## Task 6: Migration verification gate (lint + build + relaunch)

No translating happens until this passes.

**Files:**
- Create: `Tools/loc/lint_english_literals.py`
- Create: `Tools/loc/tests/test_lint.py`

- [ ] **Step 1: Write the failing test**

Create `Tools/loc/tests/test_lint.py`:

```python
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lint_english_literals import offending_literals

class TestLint(unittest.TestCase):
    def test_flags_english_literal(self):
        src = 'Text("Pause all", bundle: .module)'
        self.assertEqual(offending_literals(src), ["Pause all"])

    def test_accepts_dotted_key(self):
        src = 'Text("queue.pauseAll.button", bundle: .module)'
        self.assertEqual(offending_literals(src), [])

    def test_ignores_format_specifier_only(self):
        # pure interpolation, no user text
        src = 'Text("\\(count)", bundle: .module)'
        self.assertEqual(offending_literals(src), [])

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest Tools.loc.tests.test_lint -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'lint_english_literals'`

- [ ] **Step 3: Implement `lint_english_literals.py`**

Create `Tools/loc/lint_english_literals.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest Tools.loc.tests.test_lint -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Run the lint against the codebase**

Run: `python3 Tools/loc/lint_english_literals.py`
Expected: `0 offending literals` → exit 0. If any appear, add them to `mapping.json`, re-run
Tasks 4–5 for those keys, and re-lint.

- [ ] **Step 6: Build + relaunch for visual raw-key check**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```
Expected: app launches; spot-check Queue / Settings / Chat / Discover / Search for any raw
`area.component.role` text leaking into the UI. Fix mapping/migration if found.

- [ ] **Step 7: Commit**

```bash
git add Tools/loc/lint_english_literals.py Tools/loc/tests/test_lint.py
git commit -m "test(loc): english-literal lint gate"
```

---

## Task 7: Polish gold pass + glossary

Content task. Acceptance: PL clean per audit, glossary committed, build + relaunch OK.

**Files:**
- Create: `Tools/loc/glossary.md`
- Modify: `Localizable.xcstrings` (pl values)

- [ ] **Step 1: Author the glossary**

Create `Tools/loc/glossary.md` — one row per recurring term with the canonical PL translation and
columns for de/es/fr/nl (filled in Task 9). Seed it from the catalog's recurring nouns/verbs:

```markdown
| concept | en | pl | de | es | fr | nl |
|---------|----|----|----|----|----|----|
| queue | Queue | Kolejka | | | | |
| download (n) | Download | Pobieranie | | | | |
| download (v) | Download | Pobierz | | | | |
| monitor (v) | Monitor | Monitoruj | | | | |
| upcoming | Upcoming | Nadchodzące | | | | |
| library | Library | Biblioteka | | | | |
| season | Season | Sezon | | | | |
| episode | Episode | Odcinek | | | | |
| track | Track | Utwór | | | | |
| artist | Artist | Wykonawca | | | | |
| pick (quiz) | Pick | Typ / Wybór | | | | |
| pause | Pause | Wstrzymaj | | | | |
| resume | Resume | Wznów | | | | |
| delete | Delete | Usuń | | | | |
| search | Search | Szukaj | | | | |
| settings | Settings | Ustawienia | | | | |
```
Extend with every term that appears 3+ times across the catalog.

- [ ] **Step 2: Audit every PL string (manual, area by area)**

Apply the Tone Guidelines from the spec: imperative verbs for buttons, no "Proszę…"/"Aby…" filler,
no literal idiom translation, respect each key's `comment` context, and enforce the glossary term
for every occurrence. Edit `pl` values directly in `Localizable.xcstrings`. The Polish example
string moves here: `discover.tryExample.saturdayNight` → pl value `"Spróbuj: zaskocz mnie quizem na sobotni wieczór"`.

- [ ] **Step 3: Audit passes**

Run: `python3 Tools/loc/loc_audit.py Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings --langs en,pl`
Expected: exit 0 (all clean).

- [ ] **Step 4: Build + relaunch in Polish**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app -W --args -AppleLanguages '(pl)'
```
Expected: UI reads naturally in Polish across tabs.

- [ ] **Step 5: Commit**

```bash
git add Tools/loc/glossary.md Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "feat(loc): Polish gold pass + terminology glossary"
```

---

## Task 8: Plurals (CLDR variations)

**Files:**
- Create: `Tools/loc/build_plurals.py`
- Create: `Tools/loc/tests/test_build_plurals.py`
- Modify: `Localizable.xcstrings` (unit.* + discover.pickedCount entries)

- [ ] **Step 1: Write the failing test**

Create `Tools/loc/tests/test_build_plurals.py`:

```python
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_plurals import make_plural_unit

class TestPlural(unittest.TestCase):
    def test_polish_has_four_categories(self):
        forms = {"one": "%lld dzień", "few": "%lld dni", "many": "%lld dni", "other": "%lld dnia"}
        unit = make_plural_unit(forms)
        cats = unit["variations"]["plural"]
        self.assertEqual(set(cats), {"one", "few", "many", "other"})
        self.assertEqual(cats["few"]["stringUnit"]["value"], "%lld dni")

    def test_english_two_categories(self):
        unit = make_plural_unit({"one": "%lld day", "other": "%lld days"})
        self.assertEqual(set(unit["variations"]["plural"]), {"one", "other"})

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest Tools.loc.tests.test_build_plurals -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'build_plurals'`

- [ ] **Step 3: Implement `build_plurals.py`**

Create `Tools/loc/build_plurals.py`:

```python
#!/usr/bin/env python3
"""Helper to construct xcstrings plural-variation stringUnits."""

def make_plural_unit(forms):
    """forms: {category: value}. Returns a localization unit with variations.plural."""
    return {"variations": {"plural": {
        cat: {"stringUnit": {"state": "translated", "value": val}}
        for cat, val in forms.items()}}}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest Tools.loc.tests.test_build_plurals -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Convert the plural keys in the catalog (manual, using the helper forms)**

For each plural key (`unit.days`, `unit.episodes`, `unit.downloads`, `unit.tracks`,
`unit.itemsNamed`, `discover.pickedCount`), replace the flat `stringUnit` with a `variations.plural`
unit per language. Categories per language: en/de/nl/es → one, other; fr → one, many, other;
pl → one, few, many, other. Example for `unit.episodes` (en + pl):

```json
"unit.episodes" : {
  "comment" : "Count of episodes, e.g. queue badge",
  "localizations" : {
    "en" : { "variations" : { "plural" : {
      "one"   : { "stringUnit" : { "state" : "translated", "value" : "%lld episode" } },
      "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld episodes" } } } } },
    "pl" : { "variations" : { "plural" : {
      "one"   : { "stringUnit" : { "state" : "translated", "value" : "%lld odcinek" } },
      "few"   : { "stringUnit" : { "state" : "translated", "value" : "%lld odcinki" } },
      "many"  : { "stringUnit" : { "state" : "translated", "value" : "%lld odcinków" } },
      "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld odcinka" } } } } }
  }
}
```

- [ ] **Step 6: Build + verify plurals render**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app -W --args -AppleLanguages '(pl)'
```
Expected: counts read correctly (e.g. "1 odcinek", "2 odcinki", "5 odcinków").

- [ ] **Step 7: Commit**

```bash
git add Tools/loc/build_plurals.py Tools/loc/tests/test_build_plurals.py \
        Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "fix(loc): proper CLDR plural variations"
```

---

## Task 9: Regenerate de / es / fr / nl from canonical EN

Content task, calibrated to PL + glossary. Optionally parallelized via a workflow (user opt-in).

**Files:**
- Modify: `Localizable.xcstrings` (de/es/fr/nl values, including plural variations)
- Modify: `Tools/loc/glossary.md` (fill de/es/fr/nl columns first)

- [ ] **Step 1: Fill the glossary's de/es/fr/nl columns**

Decide the canonical term per language before translating any string, so terminology is locked.

- [ ] **Step 2: Translate every key for de, then es, then fr, then nl**

For each language, translate from the `en` value using the `comment` for context and the glossary
for terminology, matching the human tone established in PL. Add plural variations per that
language's CLDR categories (de/es/nl: one/other; fr: one/many/other). Write values directly into
`Localizable.xcstrings`.

- [ ] **Step 3: Audit all five languages**

Run: `python3 Tools/loc/loc_audit.py Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`
Expected: exit 0 — 0 empty, 0 missing, 0 new, across en/pl/de/es/fr/nl.

- [ ] **Step 4: Build + relaunch per language spot-check**

For each of de/es/fr/nl:
```bash
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app -W --args -AppleLanguages '(de)'
```
(swap the code). Expected: natural, complete UI; no overflow/truncation regressions.

- [ ] **Step 5: Commit**

```bash
git add Tools/loc/glossary.md Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "feat(loc): regenerate de/es/fr + add Dutch (nl)"
```

---

## Task 10: Final verification

**Files:** none (verification only).

- [ ] **Step 1: Full catalog audit**

Run: `python3 Tools/loc/loc_audit.py Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`
Expected: exit 0.

- [ ] **Step 2: English-literal lint**

Run: `python3 Tools/loc/lint_english_literals.py`
Expected: `0 offending literals` → exit 0.

- [ ] **Step 3: Tool unit tests**

Run: `python3 -m unittest discover -s Tools/loc/tests -v`
Expected: all pass.

- [ ] **Step 4: Swift package tests**

```bash
(cd Packages/ArrCore && swift test)
(cd Packages/ArrMCPServer && swift test)
```
Expected: all pass.

- [ ] **Step 5: Release build (catches APPSTORE-flag string usage)**

Run: `xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Final relaunch**

```bash
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```
Expected: app runs in the system language, fully localized.

- [ ] **Step 7: Finishing the branch**

Use the superpowers:finishing-a-development-branch skill to decide merge/PR/cleanup for
`localization-overhaul`.

---

## Self-Review notes

- **Spec coverage:** semantic keys (T2–T5), canonical EN + comments (T4), PL gold + glossary (T7),
  de/es/fr/nl from scratch + Dutch (T9), plurals (T8), no empty/missing (audit gates in T6/T10),
  dirty-key cleanup (T3 step 5, T5 step 7). All spec sections map to a task.
- **Naming consistency:** `mapping.json` record fields (`oldKey/newKey/en/comment/area/role/usages/
  needsReview/plural`) are used identically across `build_mapping`, `check_mapping`, `apply_mapping`,
  `migrate_code`. `make_plural_unit(forms)` signature consistent T8.
- **Known judgment points (not placeholders):** T3 finalize naming, T7 PL wording, T9 translations —
  these are inherently human/agent content decisions, each gated by `loc_audit.py` exit 0 + build.
