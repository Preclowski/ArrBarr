# Search Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Search tab (Radarr + Sonarr) to the ArrBarr popover — query → results → slide-in add panel → POST to arr.

**Architecture:** New `SearchClient` actor (per-source) for all network calls; `SearchViewModel` owns debounce + state; `SearchView` / `SearchAddPanel` mirror the existing History slide-in pattern in `PopoverContentView`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`), existing `HTTPClient`

**Spec:** `docs/superpowers/specs/2026-05-04-search-tab-design.md`

---

### Task 1: Data models (`SearchTypes.swift` + `ArrTypes.swift`)

**Files:**
- Create: `ArrBarr/Models/SearchTypes.swift`
- Modify: `ArrBarr/Models/ArrTypes.swift`
- Test: `ArrBarrTests/SearchDecodingTests.swift`

- [ ] **Create `ArrBarr/Models/SearchTypes.swift`**

```swift
import Foundation

// MARK: - Shared

struct QualityProfile: Decodable, Identifiable {
    let id: Int
    let name: String
}

struct RootFolder: Decodable, Identifiable {
    let id: Int
    let path: String
}

// MARK: - Search result (unified)

struct SearchResult: Identifiable {
    let id: Int                  // arr's internal id (tmdbId for Radarr, tvdbId for Sonarr)
    let foreignId: String        // tmdbId/tvdbId as string — used in POST body
    let title: String
    let subtitle: String?        // nil for movies; "X seasons" for shows
    let year: Int?
    let rating: Double?
    let overview: String?
    let runtime: Int?            // minutes; nil for Sonarr
    let posterURL: URL?
    let source: QueueItem.Source
}

// MARK: - Monitor modes

enum RadarrMonitorMode: String, CaseIterable, Identifiable {
    case movieOnly, movieAndCollection, none
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .movieOnly: return "Movie Only"
        case .movieAndCollection: return "Movie & Collection"
        case .none: return "None"
        }
    }
}

enum SonarrMonitorMode: String, CaseIterable, Identifiable {
    case all, future, missing, existing, first, latest, none
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return "All"
        case .future: return "Future"
        case .missing: return "Missing"
        case .existing: return "Existing"
        case .first: return "First Season"
        case .latest: return "Latest Season"
        case .none: return "None"
        }
    }
}

enum SonarrSeriesType: String, CaseIterable, Identifiable {
    case standard, daily, anime
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}
```

- [ ] **Append lookup decode structs to `ArrBarr/Models/ArrTypes.swift`**

```swift
// MARK: - Search Lookup

struct RadarrLookupRecord: Decodable {
    let tmdbId: Int?
    let title: String
    let year: Int?
    let overview: String?
    let runtime: Int?
    let ratings: RadarrRatings?
    let images: [ArrImage]?
}

struct RadarrRatings: Decodable {
    let tmdb: RadarrRatingValue?
}
struct RadarrRatingValue: Decodable {
    let value: Double?
}

struct SonarrLookupRecord: Decodable {
    let tvdbId: Int?
    let title: String
    let year: Int?
    let overview: String?
    let ratings: SonarrRatings?
    let images: [ArrImage]?
    let statistics: SonarrLookupStats?
}

struct SonarrRatings: Decodable {
    let value: Double?
}

struct SonarrLookupStats: Decodable {
    let seasonCount: Int?
}

// Used to fetch existing library ids
struct RadarrLibraryRecord: Decodable { let tmdbId: Int? }
struct SonarrLibraryRecord: Decodable { let tvdbId: Int? }
```

- [ ] **Write `ArrBarrTests/SearchDecodingTests.swift`**

```swift
import Testing
import Foundation
@testable import ArrBarr

@Suite("Search Decoding")
struct SearchDecodingTests {
    @Test("Decodes Radarr lookup record")
    func radarrLookup() throws {
        let json = """
        [{"tmdbId":438631,"title":"Dune: Part Two","year":2024,
          "overview":"Paul Atreides...","runtime":166,
          "ratings":{"tmdb":{"value":8.5}},
          "images":[{"coverType":"poster","remoteUrl":"https://example.com/p.jpg"}]}]
        """.data(using: .utf8)!
        let records = try JSONDecoder().decode([RadarrLookupRecord].self, from: json)
        #expect(records[0].tmdbId == 438631)
        #expect(records[0].title == "Dune: Part Two")
        #expect(records[0].ratings?.tmdb?.value == 8.5)
    }

    @Test("Decodes Sonarr lookup record")
    func sonarrLookup() throws {
        let json = """
        [{"tvdbId":81189,"title":"Breaking Bad","year":2008,
          "overview":"A teacher...","ratings":{"value":9.5},
          "statistics":{"seasonCount":5},
          "images":[]}]
        """.data(using: .utf8)!
        let records = try JSONDecoder().decode([SonarrLookupRecord].self, from: json)
        #expect(records[0].tvdbId == 81189)
        #expect(records[0].statistics?.seasonCount == 5)
    }
}
```

- [ ] **Run tests**

```bash
xcodebuild test -project ArrBarr.xcodeproj -scheme ArrBarr -destination 'platform=macOS' 2>&1 | grep -E "passed|failed|error:"
```
Expected: new suite passes.

- [ ] **Commit**

```bash
git add ArrBarr/Models/SearchTypes.swift ArrBarr/Models/ArrTypes.swift ArrBarrTests/SearchDecodingTests.swift
git commit -m "feat: add search data models and lookup decode types"
```

---

### Task 2: `SearchClient.swift`

**Files:**
- Create: `ArrBarr/Services/SearchClient.swift`

- [ ] **Create `ArrBarr/Services/SearchClient.swift`**

```swift
import Foundation

actor SearchClient {
    private let config: ServiceConfig
    private let source: QueueItem.Source
    private let http = HTTPClient()

    private var apiBase: String {
        source == .lidarr ? "/api/v1" : "/api/v3"
    }

    init(config: ServiceConfig, source: QueueItem.Source) {
        self.config = config
        self.source = source
    }

    private var headers: [String: String] { ["X-Api-Key": config.apiKey] }

    // MARK: - Lookup

    func lookup(query: String) async throws -> [SearchResult] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch source {
        case .radarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie/lookup",
                                   query: [URLQueryItem(name: "term", value: encoded)])
            let data = try await http.get(url, headers: headers)
            let records = try JSONDecoder().decode([RadarrLookupRecord].self, from: data)
            return records.compactMap { Self.unifyRadarr($0, baseURL: config.baseURL) }
        case .sonarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/series/lookup",
                                   query: [URLQueryItem(name: "term", value: encoded)])
            let data = try await http.get(url, headers: headers)
            let records = try JSONDecoder().decode([SonarrLookupRecord].self, from: data)
            return records.compactMap { Self.unifySonarr($0, baseURL: config.baseURL) }
        case .lidarr:
            return [] // future
        }
    }

    // MARK: - Library filter

    func fetchLibraryIds() async throws -> Set<Int> {
        guard config.isConfigured else { return [] }
        switch source {
        case .radarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie")
            let data = try await http.get(url, headers: headers)
            let records = (try? JSONDecoder().decode([RadarrLibraryRecord].self, from: data)) ?? []
            return Set(records.compactMap(\.tmdbId))
        case .sonarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/series")
            let data = try await http.get(url, headers: headers)
            let records = (try? JSONDecoder().decode([SonarrLibraryRecord].self, from: data)) ?? []
            return Set(records.compactMap(\.tvdbId))
        case .lidarr:
            return []
        }
    }

    // MARK: - Profiles & folders

    func fetchQualityProfiles() async throws -> [QualityProfile] {
        guard config.isConfigured else { return [] }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/qualityprofile")
        let data = try await http.get(url, headers: headers)
        return (try? JSONDecoder().decode([QualityProfile].self, from: data)) ?? []
    }

    func fetchRootFolders() async throws -> [RootFolder] {
        guard config.isConfigured else { return [] }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/rootfolder")
        let data = try await http.get(url, headers: headers)
        return (try? JSONDecoder().decode([RootFolder].self, from: data)) ?? []
    }

    // MARK: - Add

    func addMovie(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie")
        let body: [String: Any] = [
            "tmdbId": result.id,
            "title": result.title,
            "qualityProfileId": qualityProfileId,
            "rootFolderPath": rootFolderPath,
            "monitored": true,
            "monitor": monitor.rawValue,
            "addOptions": ["searchForMovie": true]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await http.post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: data)
    }

    func addSeries(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                   monitor: SonarrMonitorMode, seriesType: SonarrSeriesType,
                   seasonFolder: Bool) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/series")
        let body: [String: Any] = [
            "tvdbId": result.id,
            "title": result.title,
            "qualityProfileId": qualityProfileId,
            "rootFolderPath": rootFolderPath,
            "monitored": true,
            "seriesType": seriesType.rawValue,
            "seasonFolder": seasonFolder,
            "addOptions": [
                "monitor": monitor.rawValue,
                "searchForMissingEpisodes": true
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await http.post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: data)
    }

    // MARK: - Unify

    private static func unifyRadarr(_ r: RadarrLookupRecord, baseURL: String) -> SearchResult? {
        guard let tmdbId = r.tmdbId else { return nil }
        let (poster, _) = pickPosterURL(from: r.images, coverTypes: ["poster"], baseURL: baseURL)
        return SearchResult(
            id: tmdbId, foreignId: String(tmdbId),
            title: r.title, subtitle: nil,
            year: r.year, rating: r.ratings?.tmdb?.value,
            overview: r.overview, runtime: r.runtime,
            posterURL: poster, source: .radarr
        )
    }

    private static func unifySonarr(_ r: SonarrLookupRecord, baseURL: String) -> SearchResult? {
        guard let tvdbId = r.tvdbId else { return nil }
        let (poster, _) = pickPosterURL(from: r.images, coverTypes: ["poster"], baseURL: baseURL)
        let seasons = r.statistics?.seasonCount
        let subtitle = seasons.map { "\($0) season\($0 == 1 ? "" : "s")" }
        return SearchResult(
            id: tvdbId, foreignId: String(tvdbId),
            title: r.title, subtitle: subtitle,
            year: r.year, rating: r.ratings?.value,
            overview: r.overview, runtime: nil,
            posterURL: poster, source: .sonarr
        )
    }
}
```

- [ ] **Build to verify**

```bash
xcodebuild build -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build 2>&1 | grep -E "error:|Build succeeded"
```

- [ ] **Commit**

```bash
git add ArrBarr/Services/SearchClient.swift ArrBarr/Services/HTTPClient.swift
git commit -m "feat: add SearchClient with lookup, library filter, add movie/series"
```

---

### Task 3: `SearchViewModel.swift`

**Files:**
- Create: `ArrBarr/ViewModels/SearchViewModel.swift`

- [ ] **Create `ArrBarr/ViewModels/SearchViewModel.swift`**

```swift
import Foundation
import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [SearchResult] = []
    @Published var isSearching = false
    @Published var errorMessage: String?

    // Add panel state
    @Published var qualityProfiles: [QualityProfile] = []
    @Published var rootFolders: [RootFolder] = []
    @Published var isLoadingOptions = false
    @Published var addError: String?
    @Published var isAdding = false

    private var libraryIds: Set<Int> = []
    private var searchTask: Task<Void, Never>?
    private var radarrClient: SearchClient?
    private var sonarrClient: SearchClient?

    func setup(radarrConfig: ServiceConfig, sonarrConfig: ServiceConfig) {
        if radarrConfig.isConfigured { radarrClient = SearchClient(config: radarrConfig, source: .radarr) }
        if sonarrConfig.isConfigured { sonarrClient = SearchClient(config: sonarrConfig, source: .sonarr) }
    }

    func onQueryChange(source: QueueItem.Source) {
        searchTask?.cancel()
        results = []
        errorMessage = nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(source: source)
        }
    }

    func resetForSource() {
        results = []
        errorMessage = nil
        libraryIds = []
        searchTask?.cancel()
    }

    private func search(source: QueueItem.Source) async {
        let client = client(for: source)
        guard let client else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            async let fetchResults = client.lookup(query: query)
            async let fetchLibrary = client.fetchLibraryIds()
            let (raw, ids) = try await (fetchResults, fetchLibrary)
            libraryIds = ids
            results = raw.filter { !ids.contains($0.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadOptions(source: QueueItem.Source) async {
        let client = client(for: source)
        guard let client else { return }
        isLoadingOptions = true
        defer { isLoadingOptions = false }
        async let profiles = client.fetchQualityProfiles()
        async let folders = client.fetchRootFolders()
        qualityProfiles = (try? await profiles) ?? []
        rootFolders = (try? await folders) ?? []
    }

    func addMovie(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode) async {
        guard let client = radarrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            try await client.addMovie(result, qualityProfileId: qualityProfileId,
                                      rootFolderPath: rootFolderPath, monitor: monitor)
            results.removeAll { $0.id == result.id }
        } catch {
            addError = error.localizedDescription
        }
    }

    func addSeries(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                   monitor: SonarrMonitorMode, seriesType: SonarrSeriesType,
                   seasonFolder: Bool) async {
        guard let client = sonarrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            try await client.addSeries(result, qualityProfileId: qualityProfileId,
                                       rootFolderPath: rootFolderPath, monitor: monitor,
                                       seriesType: seriesType, seasonFolder: seasonFolder)
            results.removeAll { $0.id == result.id }
        } catch {
            addError = error.localizedDescription
        }
    }

    private func client(for source: QueueItem.Source) -> SearchClient? {
        source == .radarr ? radarrClient : sonarrClient
    }
}
```

- [ ] **Build**

```bash
xcodebuild build -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build 2>&1 | grep -E "error:|Build succeeded"
```

- [ ] **Commit**

```bash
git add ArrBarr/ViewModels/SearchViewModel.swift
git commit -m "feat: add SearchViewModel with debounce, library filter, add actions"
```

---

### Task 4: `SearchResultRow.swift` + `SearchView.swift`

**Files:**
- Create: `ArrBarr/Views/SearchResultRow.swift`
- Create: `ArrBarr/Views/SearchView.swift`

- [ ] **Create `ArrBarr/Views/SearchResultRow.swift`**

```swift
import SwiftUI

struct SearchResultRow: View {
    let result: SearchResult
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                RemotePoster(url: result.posterURL, requiresAuth: false)
                    .frame(width: 26, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let year = result.year {
                            Text(verbatim: "\(year)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let sub = result.subtitle {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(sub)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let r = result.rating {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(String(format: "★%.1f", r))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Create `ArrBarr/Views/SearchView.swift`**

```swift
import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    let configuredSources: [QueueItem.Source]
    let onSelectResult: (SearchResult) -> Void

    @State private var selectedSource: QueueItem.Source

    init(viewModel: SearchViewModel, configuredSources: [QueueItem.Source],
         onSelectResult: @escaping (SearchResult) -> Void) {
        self.viewModel = viewModel
        self.configuredSources = configuredSources
        self.onSelectResult = onSelectResult
        _selectedSource = State(initialValue: configuredSources.first ?? .radarr)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField(placeholder, text: $viewModel.query)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .onChange(of: viewModel.query) { _, _ in
                        viewModel.onQueryChange(source: selectedSource)
                    }
                if !viewModel.query.isEmpty {
                    Button { viewModel.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Sub-tabs (only if >1 source)
            if configuredSources.count > 1 {
                subTabs
            }

            Divider().padding(.top, 4)

            // Results area
            ScrollView {
                resultContent
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 440)
        }
        .onChange(of: selectedSource) { _, _ in
            viewModel.resetForSource()
            if !viewModel.query.isEmpty {
                viewModel.onQueryChange(source: selectedSource)
            }
        }
    }

    private var placeholder: String {
        selectedSource == .radarr ? "Search movies…" : "Search shows…"
    }

    private var subTabs: some View {
        HStack(spacing: 0) {
            ForEach(configuredSources, id: \.self) { source in
                Button {
                    selectedSource = source
                } label: {
                    VStack(spacing: 0) {
                        Text(source.displayName)
                            .font(.system(size: 11, weight: selectedSource == source ? .semibold : .regular))
                            .foregroundStyle(selectedSource == source ? .primary : .secondary)
                            .padding(.vertical, 6)
                        Rectangle()
                            .fill(selectedSource == source ? Color.accentColor : Color.clear)
                            .frame(height: 1.5)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var resultContent: some View {
        if viewModel.isSearching {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if let err = viewModel.errorMessage {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(12)
        } else if viewModel.query.isEmpty {
            EmptyView()
        } else if viewModel.results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No results")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.results) { result in
                    SearchResultRow(result: result) { onSelectResult(result) }
                    if result.id != viewModel.results.last?.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
```

- [ ] **Build**

```bash
xcodebuild build -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build 2>&1 | grep -E "error:|Build succeeded"
```

- [ ] **Commit**

```bash
git add ArrBarr/Views/SearchResultRow.swift ArrBarr/Views/SearchView.swift
git commit -m "feat: add SearchView with sub-tabs, debounced field, and result rows"
```

---

### Task 5: `SearchAddPanel.swift`

**Files:**
- Create: `ArrBarr/Views/SearchAddPanel.swift`

- [ ] **Create `ArrBarr/Views/SearchAddPanel.swift`**

```swift
import SwiftUI

struct SearchAddPanel: View {
    let result: SearchResult
    @ObservedObject var viewModel: SearchViewModel
    let onBack: () -> Void

    // Radarr state
    @State private var selectedProfileId: Int?
    @State private var selectedRootFolder: String?
    @State private var radarrMonitor: RadarrMonitorMode = .movieOnly

    // Sonarr state
    @State private var sonarrMonitor: SonarrMonitorMode = .all
    @State private var seriesType: SonarrSeriesType = .standard
    @State private var seasonFolder = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Results")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.accent)
                }
                .buttonStyle(.plain)

                Spacer()
                Text(result.source == .radarr ? "Add to Radarr" : "Add to Sonarr")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // balance the back button width
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    Divider().padding(.vertical, 8)
                    if viewModel.isLoadingOptions {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 16)
                    } else {
                        if result.source == .radarr {
                            radarrForm
                        } else {
                            sonarrForm
                        }
                    }
                    if let err = viewModel.addError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    }
                    addButton
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 480)
        }
        .task {
            await viewModel.loadOptions(source: result.source)
            selectedProfileId = viewModel.qualityProfiles.first?.id
            selectedRootFolder = viewModel.rootFolders.first?.path
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 10) {
            RemotePoster(url: result.posterURL, requiresAuth: false)
                .frame(width: 44, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(2)

                HStack(spacing: 4) {
                    if let y = result.year { Text(verbatim: "\(y)").foregroundStyle(.secondary) }
                    if let r = result.rating {
                        Text("·").foregroundStyle(.tertiary)
                        Text(String(format: "★%.1f", r)).foregroundStyle(.secondary)
                    }
                    if let rt = result.runtime {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(rt)m").foregroundStyle(.secondary)
                    }
                    if let sub = result.subtitle {
                        Text("·").foregroundStyle(.tertiary)
                        Text(sub).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10))

                if let ov = result.overview {
                    Text(ov)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    // MARK: - Radarr form

    private var radarrForm: some View {
        VStack(spacing: 4) {
            formPicker("Quality Profile",
                       selection: Binding(
                           get: { selectedProfileId ?? viewModel.qualityProfiles.first?.id ?? 0 },
                           set: { selectedProfileId = $0 }
                       ),
                       options: viewModel.qualityProfiles.map { ($0.id, $0.name) })

            formPicker("Root Folder",
                       selection: Binding(
                           get: { selectedRootFolder ?? viewModel.rootFolders.first?.path ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: viewModel.rootFolders.map { ($0.path, $0.path) })

            formPicker("Monitor",
                       selection: $radarrMonitor,
                       options: RadarrMonitorMode.allCases.map { ($0, $0.displayName) })
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Sonarr form

    private var sonarrForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Library")
            VStack(spacing: 4) {
                formPicker("Quality Profile",
                           selection: Binding(
                               get: { selectedProfileId ?? viewModel.qualityProfiles.first?.id ?? 0 },
                               set: { selectedProfileId = $0 }
                           ),
                           options: viewModel.qualityProfiles.map { ($0.id, $0.name) })

                formPicker("Root Folder",
                           selection: Binding(
                               get: { selectedRootFolder ?? viewModel.rootFolders.first?.path ?? "" },
                               set: { selectedRootFolder = $0 }
                           ),
                           options: viewModel.rootFolders.map { ($0.path, $0.path) })

                formPicker("Series Type",
                           selection: $seriesType,
                           options: SonarrSeriesType.allCases.map { ($0, $0.displayName) })
            }

            sectionLabel("Monitor")
            monitorChips

            Toggle(isOn: $seasonFolder) {
                Text("Season Folders")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }

    private var monitorChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(SonarrMonitorMode.allCases) { mode in
                    Button {
                        sonarrMonitor = mode
                    } label: {
                        Text(mode.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(sonarrMonitor == mode
                                ? Color.accentColor.opacity(0.2)
                                : Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(sonarrMonitor == mode ? .accent : .secondary)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(sonarrMonitor == mode ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Add button

    private var addButton: some View {
        Button {
            Task {
                if result.source == .radarr {
                    guard let pid = selectedProfileId ?? viewModel.qualityProfiles.first?.id,
                          let folder = selectedRootFolder ?? viewModel.rootFolders.first?.path else { return }
                    await viewModel.addMovie(result, qualityProfileId: pid,
                                            rootFolderPath: folder, monitor: radarrMonitor)
                } else {
                    guard let pid = selectedProfileId ?? viewModel.qualityProfiles.first?.id,
                          let folder = selectedRootFolder ?? viewModel.rootFolders.first?.path else { return }
                    await viewModel.addSeries(result, qualityProfileId: pid,
                                             rootFolderPath: folder, monitor: sonarrMonitor,
                                             seriesType: seriesType, seasonFolder: seasonFolder)
                }
                if viewModel.addError == nil { onBack() }
            }
        } label: {
            Group {
                if viewModel.isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    Text(result.source == .radarr ? "Add to Radarr" : "Add to Sonarr")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .disabled(viewModel.isAdding || viewModel.isLoadingOptions)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func formPicker<T: Hashable>(_ label: String, selection: Binding<T>,
                                         options: [(T, String)]) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(options, id: \.0) { val, name in
                    Button(name) { selection.wrappedValue = val }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(options.first(where: { $0.0 == selection.wrappedValue })?.1
                         ?? options.first?.1 ?? "—")
                        .font(.system(size: 11))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
```

- [ ] **Build**

```bash
xcodebuild build -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build 2>&1 | grep -E "error:|Build succeeded"
```

- [ ] **Commit**

```bash
git add ArrBarr/Views/SearchAddPanel.swift
git commit -m "feat: add SearchAddPanel slide-in form"
```

---

### Task 6: Wire into `PopoverContentView.swift`

**Files:**
- Modify: `ArrBarr/Views/PopoverContentView.swift`

- [ ] **Add `.search` to the `Tab` enum and `searchViewModel` state** — edit `PopoverContentView.swift`:

```swift
// In enum Tab:
enum Tab: String, CaseIterable {
    case queue = "Queue"
    case upcoming = "Upcoming"
    case search = "Search"
}
```

Add state vars near the top of `PopoverContentView`:

```swift
@StateObject private var searchViewModel = SearchViewModel()
@State private var searchResult: SearchResult?   // non-nil = add panel shown
```

- [ ] **Compute configured search sources and set up viewModel** — add computed var and `onAppear`:

```swift
private var searchSources: [QueueItem.Source] {
    [
        sonarrConfigured ? QueueItem.Source.sonarr : nil,
        radarrConfigured ? QueueItem.Source.radarr : nil,
    ].compactMap { $0 }
}

private var searchConfigured: Bool { !searchSources.isEmpty }
```

Wire `setup` inside the existing `body` or via `.onAppear`:

```swift
.onAppear {
    searchViewModel.setup(
        radarrConfig: configStore.radarr,
        sonarrConfig: configStore.sonarr
    )
}
```

- [ ] **Hide Search tab when unconfigured** — update `tabBar` to filter tabs:

```swift
private var visibleTabs: [Tab] {
    Tab.allCases.filter { tab in
        if tab == .search { return searchConfigured }
        return true
    }
}
```

Replace `ForEach(Tab.allCases, ...)` with `ForEach(visibleTabs, ...)` in `tabBar`.

- [ ] **Add search case to content switch** — in `mainContent`, inside the `Group { switch selectedTab ... }` block, add the `.search` case. Handle the two panel states (add panel vs search list):

```swift
case .search:
    if let result = searchResult {
        SearchAddPanel(result: result, viewModel: searchViewModel) {
            searchResult = nil
        }
    } else {
        SearchView(
            viewModel: searchViewModel,
            configuredSources: searchSources
        ) { result in
            searchResult = result
        }
    }
```

- [ ] **Build and run**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|Build succeeded"
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

Click the menu bar icon → verify Search tab appears → type a query → tap a result → verify add panel opens.

- [ ] **Commit**

```bash
git add ArrBarr/Views/PopoverContentView.swift
git commit -m "feat: wire Search tab into PopoverContentView"
```

---

### Task 7: Final build + smoke test

- [ ] **Run all tests**

```bash
xcodebuild test -project ArrBarr.xcodeproj -scheme ArrBarr -destination 'platform=macOS' 2>&1 | grep -E "passed|failed|error:"
```

Expected: all existing tests pass + new `SearchDecodingTests` suite passes.

- [ ] **Manual smoke test checklist**
  - Search tab hidden when no arr configured ✓
  - Search tab shows only configured arrs in sub-tabs ✓
  - Typing debounces — no request fires mid-word ✓
  - Results filtered — nothing already in library shows ✓
  - Tapping result opens add panel; back button returns to results ✓
  - Quality profiles and root folders populate from real arr ✓
  - Add button POSTs and result disappears from list ✓
  - Error from arr shown below add button ✓

- [ ] **Final commit**

```bash
git add -A
git commit -m "feat: Search tab — Radarr + Sonarr lookup and add"
```
