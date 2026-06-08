# Paywall Redesign — Contextual, In-App Style

**Date:** 2026-06-08
**Status:** Approved, implementing

## Goal

Replace the generic crown+bullet paywall with an in-app-styled screen that
**adapts its hero illustration, headline and subtitle to the gated feature**
the user just tried to use. One `PaywallView`; the contextual part switches on
`ProFeature`. Looks native to ArrBarr (Welcome-screen style), works on macOS
and iOS.

## Placement (answers "must it be a popup?")

- **macOS:** stays hosted in the existing dedicated `NSWindow` (required — the
  MenuBarExtra panel self-dismisses when StoreKit's purchase UI takes focus).
  Restyled to read as a native in-app screen (same chrome as Welcome:
  `Color.platformWindowBackground`, `scaledFont`, glass), not a system dialog.
  Window grows to ~400×580.
- **iOS:** presented as `.fullScreenCover` (immersive, full-bleed) instead of a
  small sheet.

## Layout (shared)

```
[ HERO  — contextual illustration + lock ]
   headline       (contextual)
   subtitle       (contextual)
   ─────────
   ✓ benefit 1
   ✓ benefit 2    (constant — one purchase unlocks everything)
   ✓ benefit 3
   ✓ benefit 4
   [ Unlock · <price> ]        (GlassProminentButtonStyle)
   One-time purchase. No subscription. iOS + macOS.
   Maybe later · Restore Purchases · Privacy
```

## Contextual content (per `ProFeature`)

| Feature | Hero | Headline (en) | Subtitle (en) |
|---|---|---|---|
| `chat` | chat bubbles mock | Ask your library anything | Chat drives your whole stack in plain language. |
| `queueAction` | download row mock (progress + pause/delete, locked) | Manage your downloads | Pause, resume and remove downloads right from ArrBarr. |
| `addTitle` | search-result card mock (Add CTA, locked) | Add new titles | Find a movie or show and add it in one tap. |
| `downloadClients` | row of client icons (locked) | Connect download clients | Add and manage SABnzbd, qBittorrent and the rest. |

Constant benefits (en): "Ask and manage in plain language", "Add movies and
shows in one sentence", "Pause, resume and retry without a browser", "Plus
everything else from Control mode".

## Components / files

- `ProFeature.swift` — add `paywallHeadlineKey` and `paywallSubtitleKey`
  (the hero is chosen by the enum case in the view).
- `PaywallHeroes.swift` (new) — `ChatPaywallHero`, `QueuePaywallHero`,
  `AddTitlePaywallHero`, `DownloadClientsPaywallHero`, and a `PaywallHero(feature:)`
  dispatcher. Stylized static mocks built from existing tokens/components.
- `PaywallView.swift` — rebuilt: `PaywallHero(feature:)` + contextual headline/
  subtitle + constant benefits + CTA + footer. macOS hides the in-view close
  (window titlebar + "Maybe later" cover it); iOS keeps a close.
- `iOSAppRoot.swift` — `.sheet` → `.fullScreenCover`.
- `AppDelegate.swift` — bump paywall window content size.
- `Localizable.xcstrings` — new keys (4 headlines, 4 subtitles, 4 benefits,
  "Unlock", "Maybe later", "One-time purchase. No subscription. iOS + macOS.").

## Style tokens

`scaledFont` (18 semibold headline / 12 secondary subtitle / 13 benefits),
`Tokens.Radius.panel` hero card on `.ultraThinMaterial`, lock glyph in hero
corner, `GlassProminentButtonStyle` CTA, footer links `scaledFont(11, .secondary)`.

## Out of scope

- Real live data in heroes (static mocks only).
- Per-feature benefit lists (benefits stay constant).
