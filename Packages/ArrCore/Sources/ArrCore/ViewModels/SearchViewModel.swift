import Foundation
import Combine

@MainActor
public final class SearchViewModel: ObservableObject {
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
