import Foundation
import Combine

/// App configuration persisted as plain JSON in Application Support.
/// No Keychain on purpose: the app is signed ad-hoc (free Apple account), and
/// Keychain items ACL'd to a changing signature prompt on every rebuild. The
/// TMDB key is a free-tier credential, so a file is an acceptable home.
@MainActor
public final class TonightConfig: ObservableObject {
    public static let shared = TonightConfig()

    @Published public var tmdbApiKey: String = "" { didSet { save() } }
    @Published public var watchRegion: String = "PL" { didSet { save() } }
    /// Prefer the poster your media server holds over TMDB's, for titles it
    /// has. On by default when a server is connected: that artwork is the one
    /// the user curated and the one they recognise from Plex/Jellyfin. The
    /// escape hatch exists because a server's art can also be a bad scrape or
    /// simply missing, and nobody should have to fix that in Plex to get a
    /// decent grid here.
    @Published public var useServerArtwork: Bool = true { didSet { save() } }

    // MARK: - Home layout

    /// Every Home shelf, in the order the user wants them. Always a complete
    /// permutation of `HomeSectionKind.allCases` — unknown ids from an older
    /// build are dropped and newly added kinds are appended on load, so the
    /// list never silently loses a shelf.
    @Published public var homeSectionOrder: [HomeSectionKind] = HomeSectionKind.allCases {
        didSet { save() }
    }
    /// Shelves the user switched off. Kept alongside the order so hiding a
    /// shelf and showing it again puts it back where it was.
    @Published public var hiddenHomeSections: Set<HomeSectionKind> = [
        .popularMovies, .popularSeries, .onTheAir,
    ] { didSet { save() } }
    @Published public var homeHero: HomeHeroKind = .movies { didSet { save() } }

    /// The shelves Home should actually build, in order.
    public var visibleHomeSections: [HomeSectionKind] {
        homeSectionOrder.filter { !hiddenHomeSections.contains($0) }
    }

    public func setHomeSection(_ kind: HomeSectionKind, visible: Bool) {
        if visible { hiddenHomeSections.remove(kind) } else { hiddenHomeSections.insert(kind) }
    }

    public func moveHomeSections(from source: IndexSet, to destination: Int) {
        homeSectionOrder.move(fromOffsets: source, toOffset: destination)
    }

    public func resetHomeLayout() {
        homeSectionOrder = HomeSectionKind.allCases
        hiddenHomeSections = [.popularMovies, .popularSeries, .onTheAir]
        homeHero = .movies
    }

    public var isConfigured: Bool { !tmdbApiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Explicit, stable paths — survive rebuilds regardless of code identity.
    nonisolated public static let supportDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/TonightBarr")
    nonisolated public static let configURL = supportDirectory.appending(path: "config.json")
    nonisolated public static let storeURL = supportDirectory.appending(path: "TonightBarr.store")

    private struct FileFormat: Codable {
        var tmdbApiKey: String?
        var watchRegion: String?
        var homeSectionOrder: [String]?
        var hiddenHomeSections: [String]?
        var homeHero: String?
        var useServerArtwork: Bool?
    }

    private var loading = false

    private init() {
        load()
        if !isConfigured { importFromArrBarr() }
    }

    /// Test seam: a config not wired to disk.
    public init(detached: Void) { loading = true; defer { loading = false } }

    private func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: Self.configURL),
              let file = try? JSONDecoder().decode(FileFormat.self, from: data)
        else { return }
        tmdbApiKey = file.tmdbApiKey ?? ""
        watchRegion = file.watchRegion ?? "PL"
        if let stored = file.homeSectionOrder {
            let known = stored.compactMap(HomeSectionKind.init(rawValue:))
            // Append anything this build added that the file predates.
            homeSectionOrder = known + HomeSectionKind.allCases.filter { !known.contains($0) }
        }
        if let hidden = file.hiddenHomeSections {
            hiddenHomeSections = Set(hidden.compactMap(HomeSectionKind.init(rawValue:)))
        }
        if let hero = file.homeHero.flatMap(HomeHeroKind.init(rawValue:)) { homeHero = hero }
        useServerArtwork = file.useServerArtwork ?? true
    }

    private func save() {
        guard !loading else { return }
        let file = FileFormat(tmdbApiKey: tmdbApiKey,
                              watchRegion: watchRegion,
                              homeSectionOrder: homeSectionOrder.map(\.rawValue),
                              hiddenHomeSections: hiddenHomeSections.map(\.rawValue).sorted(),
                              homeHero: homeHero.rawValue,
                              useServerArtwork: useServerArtwork)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.configURL, options: .atomic)
    }

    // MARK: - ArrBarr import

    /// Seed the TMDB key from ArrBarr when TonightBarr has none of its own.
    /// The reading is `ArrBarrProfile`'s job — this only decides whether to
    /// take the answer.
    @discardableResult
    public func importFromArrBarr() -> Bool {
        ArrBarrProfile.refresh()
        guard let key = ArrBarrProfile.tmdbAPIKey() else { return false }
        tmdbApiKey = key
        return true
    }
}
