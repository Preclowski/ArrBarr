import SwiftUI
import MediaKit

/// What the Roulette spins: the arr's library, or a TMDB list.
enum ShelfCollection: String, CaseIterable, Identifiable {
    case library, popular, inCinemas

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .library: "shelf.collection.library"
        case .popular: "shelf.collection.popular"
        case .inCinemas: "shelf.collection.inCinemas"
        }
    }

    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .popular: "flame"
        case .inCinemas: "popcorn"
        }
    }

    var isRemote: Bool { self != .library }

    /// Cinemas are movies only; TMDB lists need a TMDB key.
    static func available(for source: QueueItem.Source, tmdbConfigured: Bool) -> [ShelfCollection] {
        guard tmdbConfigured else { return [.library] }
        return source == .sonarr ? [.library, .popular] : [.library, .popular, .inCinemas]
    }
}

/// A TMDB title projected into a `LibraryEntry`, so the scene and the info block take it unchanged.
struct ShelfRemoteItem {
    let entry: LibraryEntry
    /// Opens the add panel, or the detail when the title is already in the library.
    let result: SearchResult
    let tmdbId: Int

    init(result: SearchResult, tmdbId: Int, releaseDate: String?) {
        self.result = result
        self.tmdbId = tmdbId
        let owned = result.inLibraryArrId
        entry = LibraryEntry(
            id: "tmdb-\(result.source.rawValue)-\(tmdbId)", source: result.source, arrId: owned ?? 0,
            // Sonarr's slot is a tvdbId, which TMDB doesn't give.
            externalId: result.source == .sonarr ? nil : tmdbId,
            title: result.title, year: result.year, posterURL: result.posterURL, posterRequiresAuth: false,
            state: result.libraryDownloaded ? .complete : .missing,
            sizeOnDisk: 0, fileCount: nil, totalCount: nil, fileQuality: nil, profileName: nil,
            customFormats: [], customFormatScore: 0, fileName: nil, genres: result.genres, runtime: nil,
            certification: nil, ratingImdb: nil, ratingTmdb: result.rating, ratingArr: nil,
            releaseStatus: nil, searchIndex: result.title.lowercased(),
            releaseDate: releaseDate.flatMap(Self.day)
        )
    }

    private static func day(_ s: String) -> Date? {
        try? Date(s, strategy: Date.ISO8601FormatStyle().year().month().day())
    }
}

/// TMDB lists for the Roulette, fetched once per collection and source while the tab lives.
@Observable
final class ShelfRemoteLists {
    struct Key: Hashable {
        let collection: ShelfCollection
        let source: QueueItem.Source
    }

    private(set) var items: [Key: [ShelfRemoteItem]] = [:]
    private(set) var failed: Set<Key> = []

    func load(_ key: Key, configStore: ConfigStore) async {
        guard items[key] == nil else { return }
        failed.remove(key)
        let client = configStore.tmdbClient
        do {
            switch (key.collection, key.source) {
            case (.popular, .sonarr):
                let shows = try await client.popularSeries()
                let owned = await ArrLibraryMaps.sonarrByTMDBId(config: configStore.sonarr)
                items[key] = zip(shows, TMDBSearchMapping.series(shows, libraryMap: owned)).map {
                    ShelfRemoteItem(result: $1, tmdbId: $0.id, releaseDate: $0.firstAirDate)
                }
            case (.popular, _), (.inCinemas, _):
                // The user's country, not the app language: "in cinemas" is a place.
                let movies = key.collection == .popular
                    ? try await client.popularMovies()
                    : try await client.moviesInCinemas(region: Locale.current.region?.identifier)
                let owned = await ArrLibraryMaps.radarrByTMDBId(config: configStore.radarr)
                items[key] = zip(movies, TMDBSearchMapping.movies(movies, libraryMap: owned)).map {
                    ShelfRemoteItem(result: $1, tmdbId: $0.id, releaseDate: $0.releaseDate)
                }
            case (.library, _):
                return
            }
        } catch {
            failed.insert(key)
        }
    }
}

/// The Roulette's other corner menu: which collection spins.
struct ShelfCollectionMenu: View {
    @Binding var collection: ShelfCollection
    let available: [ShelfCollection]

    var body: some View {
        Menu {
            Picker(selection: $collection) {
                ForEach(available) { c in
                    Label { Text(c.title, bundle: .module) } icon: { Image(systemName: c.symbol) }
                        .tag(c)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collection.symbol)
                    .scaledFont(size: 13, weight: .semibold)
                if collection.isRemote {
                    Text(collection.title, bundle: .module)
                        .scaledFont(size: 11, weight: .medium)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, collection.isRemote ? 10 : 0)
            .frame(minWidth: 32, minHeight: 32)
            .glassEffect(.regular, in: .capsule)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .shelfCornerHover()
        .accessibilityLabel(Text(collection.title, bundle: .module))
    }
}

/// The Roulette's corner menus lift a touch under the pointer.
private struct ShelfCornerHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.06 : 1)
            .brightness(hovering ? 0.08 : 0)
            .animation(.smooth(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func shelfCornerHover() -> some View { modifier(ShelfCornerHover()) }
}
