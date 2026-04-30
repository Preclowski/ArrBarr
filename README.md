# ArrBarr

A small native macOS menu bar app for monitoring your Radarr, Sonarr, and Lidarr download queues, upcoming media, and controlling download clients.

[![Build & Test](https://github.com/Preclowski/ArrBarr/actions/workflows/release.yml/badge.svg)](https://github.com/Preclowski/ArrBarr/actions/workflows/release.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![Size: ~1.5 MB](https://img.shields.io/badge/Size-~1.5%20MB-brightgreen)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

ArrBarr isn't a replacement for the *arr web UIs — it's a small, cute companion you keep in your menu bar. Glance at the queue, see what's airing this week, get notified when a new release is grabbed, and act on it without opening a browser tab. Available in English, German, Spanish, French, and Polish.

![ArrBarr Screenshot](screenshot.png)

## Highlights

- **Rich hover tooltip** with quality, size, score, custom-format chips, indexer, and release name. For upgrades, a side-by-side comparison with the existing file (quality, score, formats, size, filename) so you can tell at a glance whether the upgrade is actually better.
- **In-popover history** — last 50 events per arr (grabbed / imported / failed / deleted), with a dedicated icon, color, and relative time per event.
- **Pause / resume / delete** without leaving the menu bar. Delete works for *any* download client because it's routed through the arr.
- **Upcoming media calendar** — movies, episodes, and album releases grouped by date.
- **Native macOS** — pure SwiftUI + AppKit, ~1.5 MB DMG, zero third-party dependencies. Light and dark mode follow your system appearance, with Liquid Glass on macOS 26 (Tahoe) and a graceful fallback on macOS 14+.

## Supported services

- **Media managers** — Radarr, Sonarr, Lidarr
- **Usenet** — SABnzbd, NZBGet
- **Torrent** — qBittorrent, Transmission, rTorrent, Deluge

## Installation

### Homebrew

```bash
brew tap Preclowski/arrbarr
brew install --cask arrbarr
```

### Download

Download the latest `.dmg` from [Releases](../../releases) and drag ArrBarr to your Applications folder.

> **Note:** ArrBarr is not notarized (no paid Apple Developer account). macOS Gatekeeper may block the first launch. To fix this, right-click the app and choose "Open" — macOS will ask for confirmation once, then remember your choice. If that doesn't work, run:
> ```bash
> xattr -cr /Applications/ArrBarr.app
> ```

### Build from source

Requires Xcode 26+.

```bash
open ArrBarr.xcodeproj
# Build with ⌘B, Run with ⌘R
```

## Setup

1. Click the arrow icon in the menu bar
2. Open **Settings** (gear menu, right-click the icon, or ⌘,)
3. Add the URL + API key for each *arr, plus credentials for any download client you want to control

All connections are local. ArrBarr is sandboxed with network-client-only permissions.

### Keyboard shortcuts

- **⌘,** — Open Settings
- **⌘R** — Refresh queue (status menu)
- **⌘Q** — Quit ArrBarr

## Demo mode

Want to preview the UI without configuring real services? Launch with:

```bash
open /Applications/ArrBarr.app --args --demo
```

## Vibe-coded

This project was built entirely through [vibe coding](https://en.wikipedia.org/wiki/Vibe_coding) with [Claude Code](https://claude.ai/claude-code).

## License

[MIT](LICENSE)
