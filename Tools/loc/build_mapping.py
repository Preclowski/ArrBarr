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
    "NeedsYouSectionView": "queue",
    "SettingsView": "settings", "ICloudSettingsView": "settings",
    "MCPSettingsPane": "settings", "ServiceFields": "settings",
    "SiriShortcutsSettings": "settings", "ApiKeyTestButton": "settings",
    "ChatView": "chat", "ChatTabContent": "chat", "ChatEmptyStateView": "chat",
    "ChatUnavailableView": "chat", "MarkdownMessage": "chat", "RichToolResultView": "chat",
    "SuggestionPromptRow": "chat", "ShimmerThinkingLabel": "chat",
    "DiscoverTabView": "discover", "DiscoverCardView": "discover",
    "DiscoverMatchedListView": "discover", "QuizResumeCard": "discover",
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
    "PopoverEmptyState": "common", "ConfirmActionCard": "common", "InlineConfirm": "common",
    "ExistingFileBanner": "common", "LoadErrorLine": "common",
}

def slug(text, max_words=4):
    words = re.findall(r"[A-Za-z0-9]+", text)[:max_words]
    if not words:
        return "untitled"
    out = words[0].lower() + "".join(w.capitalize() for w in words[1:])
    if out[0].isdigit():            # key segments must start with a letter
        out = "n" + out
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
    """Return list of file stems referencing this literal (best-effort)."""
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
