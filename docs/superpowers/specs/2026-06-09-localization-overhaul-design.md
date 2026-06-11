# Localization Overhaul — Semantic Keys, Canonical EN, Human-Tone PL, +Dutch

**Date:** 2026-06-09
**Status:** Design approved, pending spec review → implementation plan
**Owner:** Konrad

## Summary

Rework the entire `Localizable.xcstrings` catalog so that:

1. Keys become **semantic dotted identifiers** (`area.component.role`, camelCase) instead of
   English source text. English becomes a real localization like any other.
2. **English is the clean canonical source of truth** — every key has an `en` value plus a
   `comment` describing its UI context.
3. **Polish is the human-tone reference** — fully audited by hand, no AI phrasing, captures UI
   context; it sets the quality bar and seeds the terminology glossary.
4. **All other languages (de, es, fr, nl) are regenerated from scratch** from the canonical EN,
   calibrated to the PL tone bar and the glossary. Dutch (`nl`) is added.
5. **Plurals are fixed** — flat `%lld …` strings become proper CLDR plural variations per language.
6. **No empty or missing strings** — every key resolves in all five languages.

## Current State (measured 2026-06-09)

Catalog: `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`

- `sourceLanguage: en`, version 1.1, **631 keys**.
- Style today: **source-string-as-key** — the key *is* the English text (619/631); only 12 are
  dotted identifiers.
- Languages present: `en` (source), `de`, `es`, `fr`, `pl`.
  - `de`, `es`, `fr`, `pl`: 590 translated, 41 missing each.
  - `en`: only 91 explicit entries (the key carries the source), 13 in `new` state.
- **41 keys missing from all translated languages** — newer strings (Quiz, Score, Cast, "Pause all
  downloads", AI tool descriptions, …).
- **Dirty data:** an empty-string key `""` (entry `{}`); a Polish literal used as an English key
  (`"Try: pokaż mi quiz na sobotę wieczór"`); 13 `en` strings stuck in `new` state.
- **No plural variations** anywhere. Plural-shaped flat keys (`%lld days/episodes/downloads/tracks/
  items/picked`) are used via `String(format: String(localized: "%lld …"), count)` in 5 call sites —
  grammatically broken for PL (one/few/many/other) and other languages.

Localization call-site scale (the migration blast radius):

- ~295 `Text("literal")` usages, 86 `String(localized:)`, **428 `bundle: .module`** usages total,
  across **66 `.swift` files**.

## Decisions (from brainstorming)

| # | Decision |
|---|----------|
| Key style | **Semantic dotted keys, `area.component.role`, camelCase.** e.g. `queue.pauseAll.button`, `settings.ai.providerLabel`, `discover.noMoreCards.title`, `tooltip.pauseAll`. |
| Canonical language | **English** — materialized for all 631 keys with `comment` context. |
| Reference language | **Polish** — hand-audited for human tone, seeds the glossary. |
| Other languages | **de, es, fr, nl regenerated from scratch** from canonical EN. Existing de/es/fr translations are dropped (not carried). PL is carried over (then audited). |
| New language | **Dutch (`nl`)** added. Spanish already exists and is regenerated like the others. |
| Plurals | **Fixed** — CLDR plural variations per language. |
| Context mechanism | Per-key `comment` field in xcstrings (label / tooltip / error / button / AI-tool-description / …). |

## Non-Goals

- No change to the `loc()`-free convention already in place (`Text("key", bundle: .module)` /
  `String(localized: "key", bundle: .module)`).
- No new UI, no feature changes. Pure localization + the key refactor it requires.
- No change to the MCP tool *catalog* semantics — only user-facing strings.

## Architecture

### Key naming convention

`area.component.role`, all segments camelCase.

- **area** — top-level surface: `queue`, `settings`, `chat`, `discover`, `search`, `detail`,
  `upcoming`, `history`, `onboarding`, `paywall`, `widget`, `tooltip`, `common`, `aiTool`, `error`,
  `unit` (for counts/plurals like `unit.days`, `unit.episodes`).
- **component** — the specific element or cluster: `pauseAll`, `noMoreCards`, `providerLabel`.
- **role** — optional disambiguator when the same component has multiple strings: `.button`,
  `.title`, `.subtitle`, `.placeholder`, `.tooltip`, `.error`. Omit when unambiguous.

Examples:
```
queue.pauseAll.button          "Pause all downloads"
queue.pauseAll.tooltip         "Pauses every active download (where a download client is configured)."
discover.noMoreCards.title     "No more cards"
settings.ai.providerLabel      "AI provider"
unit.episodes                  "%lld episodes"   (plural variations)
aiTool.searchToAdd.desc        "Search Sonarr/Radarr and open ArrBarr at the results to add something."
```

### The mapping artifact (Phase 0 deliverable)

A single table is the backbone of the whole migration. One row per current key:

| old key (English text) | new dotted key | EN value | comment (context) | context category |
|---|---|---|---|---|

This table drives both the catalog rewrite and the code migration, and is committed (as a
generated file or in the plan) so the migration is auditable and reproducible.

### Catalog structure after migration

- `sourceLanguage: en` unchanged.
- Every key: dotted identifier, with `en` localization (`stringUnit`, state `translated`) +
  `comment`. Plural keys carry `variations.plural` per language.
- `pl` carried over from the matched old key (then hand-audited). `de`/`es`/`fr`/`nl` populated in
  the regeneration phase.

## Phased Plan

### Phase 0 — Convention + mapping table
- Lock the naming convention (done: `area.component.role` camelCase).
- Generate the master mapping: every current key → new dotted key + EN value + `comment` +
  context category. Resolve the dirty keys here (empty `""` dropped; Polish-literal key replaced
  with a proper English example string + correct dotted key).

### Phase 1 — Rebuild the catalog (EN canon)
- Write a new `Localizable.xcstrings` keyed by dotted identifiers.
- `en` materialized for all 631 (minus the dropped empty key) with `comment`.
- Resolve the 13 `new` EN strings → `translated`.
- Carry `pl` values across via the mapping; leave `de`/`es`/`fr`/`nl` empty for now.

### Phase 2 — Migrate code call-sites
- Rewrite all `Text("…")` / `String(localized:)` / `Label` / format-string usages from English
  literals to dotted keys, file by file (66 files), using the mapping table.
- Investigate and fix the origins of the empty-string key and the Polish-literal key in code.

### Phase 3 — Verify migration (before any translating)
- **Lint:** no English-text literal remains in any `bundle: .module` call; every key referenced in
  code exists in the catalog; no catalog key is orphaned (unused) without reason.
- `xcodebuild` Debug, then kill + relaunch; spot-check key screens visually for raw-key leakage
  (`queue.pauseAll.button` showing instead of text).
- This phase must pass before translation, so all languages are translated against a stable canon.

### Phase 4 — PL gold pass + glossary
- Hand-audit every PL string for human tone and correct UI context (see Tone Guidelines).
- Produce the **glossary**: canonical term per concept (queue→kolejka, download→pobieranie,
  monitor→monitorować, upcoming→nadchodzące, library→biblioteka, season→sezon, episode→odcinek,
  track→utwór, pick/quiz, …). The glossary governs all languages.

### Phase 5 — Plurals
- Convert `unit.*` count keys to `variations.plural` with correct categories per language
  (PL: one/few/many/other; en/de/nl/es/fr per CLDR). Keep call sites unchanged (same key,
  `String(format:)`/`String(localized:)` honors variations). Verify with a build.

### Phase 6 — Regenerate de / es / fr / nl from scratch
- Translate from canonical EN, calibrated to the PL tone bar, terminology from the glossary,
  plural per each language's CLDR rules. Add `nl` to the set of known/declared languages.

### Phase 7 — Final verification
- Sanity script: every key (≈630 after dropping the empty key) × 5 languages all `translated`,
  **0 empty, 0 missing, 0 `new`**.
- `xcodebuild` (macOS) + `swift test` in both packages; kill + relaunch.

## Tone Guidelines (human, not AI)

Voice = menu-bar app: concise, direct, calm. Applied to every language, calibrated against PL.

- **Buttons / actions:** imperative verb, short. ("Pause all" → "Wstrzymaj wszystko", not
  "Proszę wstrzymać wszystkie pobierania").
- **No corporate/AI filler:** avoid "Proszę…", "Aby…" wind-ups, hedging, and literal 1:1 idiom
  translation. Translate intent, not words.
- **Respect context category** (from the `comment`): a tooltip reads differently from an error
  from an AI-tool description. The `comment` tells the translator which.
- **Consistency:** one term, one translation — enforced by the glossary.

## Risks & Mitigations

- **Silent key-leak (biggest risk):** the compiler does not flag a missing/typo'd key — it falls
  back to showing the raw key at runtime. *Mitigation:* the Phase 3 lint (no English literals left;
  every used key exists) + visual relaunch pass, gated before translation.
- **Lost translations:** dropping de/es/fr is intentional (regenerated), but PL carry-over must be
  correct. *Mitigation:* mapping table is 1:1 and reviewed; PL values verified present after Phase 1.
- **Plural call-site breakage:** *Mitigation:* keys unchanged, build-verified in Phase 5.
- **Volume (631×5):** large. *Mitigation:* optional parallel-agent workflow for the translation
  phases (user opt-in); otherwise sequential.

## Verification Strategy

- Python sanity script over the xcstrings (counts, states, empties, missing) — run in Phase 3 and 7.
- Grep-based lint for residual English literals in `bundle: .module` call sites.
- `xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug` + relaunch.
- `(cd Packages/ArrCore && swift test)` and `(cd Packages/ArrMCPServer && swift test)`.
