# ArrBarr

A lightweight macOS menu bar app for monitoring your Radarr, Sonarr, and Lidarr download queues, upcoming media, and controlling download clients.

[![Build & Test](https://github.com/Preclowski/ArrBarr/actions/workflows/release.yml/badge.svg)](https://github.com/Preclowski/ArrBarr/actions/workflows/release.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

![ArrBarr Screenshot](screenshot.png)

## Features

- **Queue monitoring** — View active downloads from Radarr, Sonarr, and Lidarr in a unified popover
- **Posters** — Movie/series/album artwork in queue and upcoming rows, with on-disk cache
- **Upcoming media** — Browse upcoming movies, TV episodes, and album releases with calendar grouping
- **Download controls** — Pause, resume, and remove downloads directly from the menu bar
- **Client support** — SABnzbd, NZBGet (Usenet) and qBittorrent, Transmission, rTorrent, Deluge (Torrent)
- **Test Connection** — Verify URL + credentials per service from Settings before saving
- **Health badges** — Surface Radarr/Sonarr/Lidarr `/health` warnings inline as section badges
- **Search / filter** — Filter the queue and upcoming lists by title or subtitle
- **Launch at login** — Toggle in Settings (uses `SMAppService`)
- **Keychain storage** — API keys and passwords stored in the macOS Keychain, not UserDefaults
- **Notifications** — System notifications for new grabs, configurable per service
- **Status bar badge** — Shows active download count with a live-updating icon
- **Right-click menu** — Quick access to refresh, settings, and quit
- **Open in browser** — Jump to any item's Radarr/Sonarr/Lidarr web page
- **Liquid Glass** — Native macOS 26 (Tahoe) glass effects with graceful fallback
- **Configurable polling** — Adjustable refresh intervals, including "Never" for manual refresh

## Installation

### Homebrew

```bash
brew tap Preclowski/arrbarr
brew install --cask arrbarr
```

### Download

Download the latest `.dmg` from [Releases](../../releases) and drag ArrBarr to your Applications folder.

> **Note:** ArrBarr is not notarized (no paid Apple Developer account). macOS Gatekeeper may block the first launch. To fix this, run:
> ```bash
> xattr -cr /Applications/ArrBarr.app
> ```
> Or right-click the app and choose "Open" — macOS will ask for confirmation once, then remember your choice.

### Build from source

Requires Xcode 26+.

```bash
open ArrBarr.xcodeproj
# Build with ⌘B, Run with ⌘R
```

## Setup

1. Click the arrow icon in the menu bar
2. Open **Settings** (gear menu or right-click the icon)
3. Enter your service URLs and API keys:
   - **Radarr** / **Sonarr** / **Lidarr** — Base URL + API key (found in Settings > General in each app)
   - **SABnzbd** — Base URL + API key (Usenet)
   - **NZBGet** — Base URL + username/password (Usenet)
   - **qBittorrent** — Base URL + username/password (Torrent)
   - **Transmission** — Base URL + username/password (Torrent)
   - **rTorrent** — XMLRPC endpoint URL + username/password (Torrent)
   - **Deluge** — Base URL + password (Torrent)

All connections go through your local network. ArrBarr is sandboxed with network-client-only permissions.

## Demo mode

Want to preview the UI without configuring real services? Launch with:

```bash
open /Applications/ArrBarr.app --args --demo
```

Or set `ARRBARR_DEMO=1` in the environment, or `defaults write com.preclowski.ArrBarr ArrBarrDemo -bool true`. The popover populates with public-domain content (Big Buck Bunny, Sintel, Pioneer One, etc.) and CC-licensed albums; posters load from `picsum.photos`.

## Architecture

```
┌────────────────────────┐  info + custom formats  ┌─────────────┐
│ Radarr/Sonarr/Lidarr   │ ──────────────────────▶ │   ArrBarr   │
└────────────────────────┘                         │  (popover)  │
                                                   └──────┬──────┘
┌────────────────────────┐  start / pause / delete        │
│   Download Clients     │ ◀──────────────────────────────┘
│ SAB/NZBGet/qBit/Trans  │
│ rTorrent/Deluge        │
└────────────────────────┘
```

- **Swift 6** with strict concurrency (`@MainActor`, `actor` isolation)
- **SwiftUI** popover and settings, **AppKit** status bar and window management
- **No third-party dependencies** — Foundation, SwiftUI, AppKit, Security, ServiceManagement, UserNotifications
- **Keychain** for secrets, on-disk cache for posters

```
ArrBarr/
├── Models/          # QueueItem, UpcomingItem, ServiceConfig, ArrImage, API types
├── Services/        # HTTP, Keychain, ImageCache, Radarr/Sonarr/Lidarr + 6 download client adapters, DemoMocks
├── ViewModels/      # QueueViewModel with optimistic updates
└── Views/           # PopoverContentView, QueueRowView, RemotePoster, SettingsView, …
```

## Vibe-coded

This project was built entirely through [vibe coding](https://en.wikipedia.org/wiki/Vibe_coding) with [Claude Code](https://claude.ai/claude-code).

## License

[MIT](LICENSE)
