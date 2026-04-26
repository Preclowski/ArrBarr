# ArrBarr

Minimalistyczna natywna aplikacja macOS żyjąca w status barze. Pokazuje kolejkę pobierania z Radarr i Sonarr, a akcje (start/pauza/usuń) wykonuje przez SABnzbd lub qBittorrent — w zależności od tego, którego klienta używa dana pozycja.

## Architektura

```
┌──────────────────┐     info + custom formats      ┌─────────────┐
│  Radarr/Sonarr   │ ──────────────────────────────▶│   ArrBarr   │
└──────────────────┘                                 │  (popover)  │
                                                     └─────┬───────┘
┌──────────────────┐     start / pause / delete           │
│ SABnzbd/qBitt.   │ ◀────────────────────────────────────┘
└──────────────────┘
```

Każdy element kolejki *arr ma `downloadId`, który mapuje się 1:1 na `nzo_id` (SABnzbd) lub hash torrenta (qBittorrent). To pozwala wyświetlić bogate metadane z *arr (custom format score, tytuł filmu/odcinka) a sterować przez klienta pobierającego.

## Wymagania

- macOS 13+ (Ventura)
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Pierwsze uruchomienie

```bash
cd arrhelper
xcodegen generate
open ArrBarr.xcodeproj
```

W Xcode: ⌘R żeby uruchomić. Po starcie aplikacja pojawi się w status barze (bez ikony w Docku).

## Konfiguracja

Po pierwszym uruchomieniu kliknij ikonę i wybierz "Settings…" w stopce popoveru. Wpisz:

- **Radarr URL** (np. `http://192.168.1.10:7878`) + API key
- **Sonarr URL** + API key
- **SABnzbd URL** + API key (opcjonalnie)
- **qBittorrent URL** + username + password (opcjonalnie)

API keye Radarr/Sonarr znajdziesz w *Settings → General*. SABnzbd: *Config → General*. qBittorrent: standardowy login Web UI.

## Struktura źródeł

```
ArrBarr/
├── ArrBarrApp.swift          # @main + AppDelegate setup
├── AppDelegate.swift         # NSStatusItem + popover lifecycle
├── Models/                   # DTOs i unified queue item
├── Services/                 # API clients + aggregator + config store
├── ViewModels/               # QueueViewModel (ObservableObject)
└── Views/                    # SwiftUI: popover, sekcje, wiersze, settings
```

## Decyzje projektowe

- **Refresh**: co 5s gdy popover otwarty, co 30s w tle (tylko żeby zaktualizować licznik na ikonie)
- **Akcja "usuń"**: usuwa wyłącznie z kolejki klienta pobierającego (SAB/qBit). *arr zostaje nietknięte.
- **Custom formats**: wyświetlane w tooltipie po najechaniu na wiersz. Pobierane razem z queue endpointem (`includeMovie=true`/`includeSeries=true`), więc bez dodatkowych requestów.
- **Sandbox**: client-side network only. Brak file access, brak entitlement Apple Events.
