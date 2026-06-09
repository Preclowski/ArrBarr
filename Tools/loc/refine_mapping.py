#!/usr/bin/env python3
"""Refine the draft mapping.json: better area inference, unique keys, comments.

Deterministic second pass over build_mapping.py output. Resolves the large
"common" bucket using (1) an expanded file->area map applied to the recorded
`usages`, then (2) keyword rules on the English text for keys grep found no
usage for. Recomputes newKey, guarantees uniqueness, writes a context comment.
"""
import json, argparse
from pathlib import Path
from build_mapping import slug, infer_role

# Expanded filename(stem) -> area, covering files the draft left in "common".
FILE_AREA = {
    # queue
    "QueueGroupRowView": "queue", "QueueRowView": "queue", "QueueListView": "queue",
    "QueueSectionView": "queue", "QueueTabContent": "queue", "DownloadSection": "queue",
    "QueueSearchResultsView": "queue", "QueueComparisonCard": "queue",
    "PauseResumeButton": "queue", "DownloadProgressCard": "queue",
    "NeedsYouSectionView": "queue", "QueueItem": "queue", "QueueViewModel": "queue",
    "QueueAggregator": "queue", "QueueItemPrimitives": "queue",
    "UpgradeDiffView": "queue", "UpgradeDiffLine": "queue",
    "NotificationCoalescer": "queue", "ProgressLine": "queue",
    # settings
    "SettingsView": "settings", "ICloudSettingsView": "settings",
    "MCPSettingsPane": "settings", "ServiceFields": "settings",
    "SiriShortcutsSettings": "settings", "ApiKeyTestButton": "settings",
    "ServiceIcon": "settings", "CustomFormatChips": "settings",
    # chat
    "ChatView": "chat", "ChatTabContent": "chat", "ChatEmptyStateView": "chat",
    "ChatUnavailableView": "chat", "MarkdownMessage": "chat", "RichToolResultView": "chat",
    "SuggestionPromptRow": "chat", "ShimmerThinkingLabel": "chat",
    "ChatProvider": "chat", "DemoChatProvider": "chat",
    # discover
    "DiscoverTabView": "discover", "DiscoverCardView": "discover",
    "DiscoverMatchedListView": "discover", "QuizResumeCard": "discover",
    "DiscoverItem": "discover", "DiscoverViewModel": "discover",
    "GenreChips": "discover",
    # search
    "SearchView": "search", "SearchAddPanel": "search", "SearchResultRow": "search",
    "QueueSearchRow": "search", "SearchTypes": "search", "SearchViewModel": "search",
    "SearchClient": "search",
    # detail
    "DetailView": "detail", "DetailViewHelpers": "detail", "MediaHeaderCard": "detail",
    "EpisodeDetailOverlay": "detail", "EpisodeQuickDetail": "detail", "CastRow": "detail",
    "SonarrDetailPanel": "detail", "RadarrDetailPanel": "detail",
    "LidarrDetailPanel": "detail", "SeasonRow": "detail", "TrackRow": "detail",
    "EpisodeRow": "detail", "ExpandableOverview": "detail", "PosterMetadataRow": "detail",
    "EpisodeRowTooltip": "detail", "ListingBadgesView": "detail",
    "MediaDetailHelpers": "detail",
    # upcoming / history
    "UpcomingRowView": "upcoming", "UpcomingTabContent": "upcoming", "UpcomingItem": "upcoming",
    "HistoryView": "history", "HistoryItem": "history",
    # onboarding / paywall
    "WelcomeView": "onboarding", "QuizFeatureCard": "onboarding", "WelcomeContent": "onboarding",
    "PaywallView": "paywall", "PaywallHeroes": "paywall", "ProFeature": "paywall",
    # intents
    "ArrBarrIntents": "intents", "NotificationActions": "intents",
    "ActionPrimitives": "intents",
    # common
    "PopoverEmptyState": "common", "ConfirmActionCard": "common", "InlineConfirm": "common",
    "ExistingFileBanner": "common", "LoadErrorLine": "common", "ConfirmCenter": "common",
    "PopoverContentView": "common", "MultiRow": "common", "Chips": "common",
    "ExistingFileLine": "common", "iOSAppRoot": "common",
}

# Ordered keyword rules (lowercased substring -> area) for keys grep missed.
# First match wins; order matters (more specific first).
KEYWORD_RULES = [
    (("quiz", "swipe", "swiping", "mood", "surprise me", "more like", "fewer like",
      "no more cards", "picks", "discover session", "cozy", "date night",
      "crowd-pleaser", "cult favorite", "decade", "describe it", "ai decides",
      "ai will pick"), "discover"),
    (("arrbarr pro", "unlock", "subscrib", "purchase", "restore", "free trial",
      "upgrade to", "pro feature", "lifetime"), "paywall"),
    (("chat tab", "ai chat", "ask in plain", "plain language", "thinking", "assistant",
      "ask about", "ask anything", "ask:", "chat with", "chat is", "chat requires",
      "your library", "clear chat", "clear conversation"), "chat"),
    (("api key", "api base", "base url", "openai", "provider", "model", "token",
      "appearance", "icloud", "mcp", "siri", "shortcut", "download client",
      "add a service", "connection", "settings"), "settings"),
    (("season", "episode", "track", "cast", "artist", "overview", "runtime",
      "genre", "rating", "studio", "network"), "detail"),
    (("download", "queue", "pause", "resume", "seed", "stalled", "torrent",
      "usenet", "import pending"), "queue"),
    (("upcoming", "airs", "premiere", "release date", "this week"), "upcoming"),
    (("history", "grabbed", "imported", "failed"), "history"),
    (("search", "add new", "add a movie", "add and"), "search"),
    (("welcome", "get started", "onboard"), "onboarding"),
]

def infer_area(rec):
    # 1) by recorded usage files
    for f in rec.get("usages", []):
        if f in FILE_AREA:
            return FILE_AREA[f]
    # 2) by keyword on English text
    low = rec["en"].lower()
    for needles, area in KEYWORD_RULES:
        if any(n in low for n in needles):
            return area
    return "common"

ROLE_LABEL = {"button": "Button", "tooltip": "Tooltip/description", "label": "Label"}

# Manual finalizations for keys the heuristic can't name well: text starting with a
# digit (invalid leading-digit segment) and Polish literals mistakenly used as the
# English source (give them a correct English value here). oldKey -> {newKey, en?}.
OVERRIDES = {
    "24 hours": {"newKey": "settings.twentyFourHours.label"},
    "3 movies in Radarr and a season in Sonarr.": {"newKey": "paywall.exampleSummary.tooltip"},
    # Plural count strings -> clean unit.* keys (get CLDR variations in Task 8).
    "%lld days": {"newKey": "unit.days"},
    "%lld hours": {"newKey": "unit.hours"},
    "%lld downloads": {"newKey": "unit.downloads"},
    "%lld episodes": {"newKey": "unit.episodes"},
    "%lld tracks": {"newKey": "unit.tracks"},
    "%lld picked": {"newKey": "discover.pickedCount"},
    "%lld items: %@": {"newKey": "unit.itemsNamed"},
    "%lld%%": {"newKey": "common.percent.label"},
    # Polish literals wrongly stored as English source keys — fix the EN value.
    "Długość": {"newKey": "discover.lengthFilter.label", "en": "Length"},
    "Dekady": {"newKey": "discover.decadeFilter.label", "en": "Decades"},
    "Try: pokaż mi quiz na sobotę wieczór": {
        "newKey": "discover.tryExample.saturdayNight",
        "en": "Try: surprise me with a Saturday-night quiz"},
    "…lub opisz słownie": {"newKey": "discover.orDescribe.placeholder",
                            "en": "…or describe it in words"},
}

def refine(records):
    out = []
    used = {}
    for rec in records:
        ov = OVERRIDES.get(rec["oldKey"])
        en = ov["en"] if (ov and "en" in ov) else rec["en"]
        area = infer_area(rec) if not ov else infer_area({**rec, "en": en})
        role = infer_role(en)
        if ov:
            key = ov["newKey"]
            used[key] = en
            out.append({
                "oldKey": rec["oldKey"], "newKey": key, "en": en,
                "comment": rec.get("comment") or f"{ROLE_LABEL.get(role, 'Label')} in {area}",
                "area": area, "role": role, "usages": rec.get("usages", []),
                "needsReview": False,
            })
            continue
        base = f"{area}.{slug(en)}.{role}"
        key = base
        n = 2
        while key in used:
            key = f"{area}.{slug(en)}{n}.{role}"
            n += 1
        used[key] = en
        out.append({
            "oldKey": rec["oldKey"],
            "newKey": key,
            "en": en,
            "comment": rec.get("comment") or f"{ROLE_LABEL.get(role, 'Label')} in {area}",
            "area": area,
            "role": role,
            "usages": rec.get("usages", []),
            "needsReview": area == "common",
        })
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mapping", default="Tools/loc/mapping.json")
    args = ap.parse_args()
    recs = json.loads(Path(args.mapping).read_text())
    refined = refine(recs)
    Path(args.mapping).write_text(json.dumps(refined, ensure_ascii=False, indent=2))
    from collections import Counter
    areas = Counter(r["area"] for r in refined)
    flagged = sum(1 for r in refined if r["needsReview"])
    print(f"refined {len(refined)} records; {flagged} still 'common'")
    print("areas:", dict(areas.most_common()))

if __name__ == "__main__":
    main()
