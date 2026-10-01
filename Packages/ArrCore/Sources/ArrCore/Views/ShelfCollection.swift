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
        var entry = LibraryEntry(
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
        entry.watched = MediaServerIndex.shared.isWatched(result.mediaServerKeys)
        self.entry = entry
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
        ShelfCornerButton(symbol: collection.symbol, title: Text(collection.title, bundle: .module), titleLeading: false) {
            Picker(selection: $collection) {
                ForEach(available) { c in
                    Label { Text(c.title, bundle: .module) } icon: { Image(systemName: c.symbol) }
                        .tag(c)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        }
    }
}

/// A glass corner button of the Roulette. Its title opens on hover toward the middle; the icon never moves.
struct ShelfCornerButton<Items: View>: View {
    let symbol: String
    let title: Text
    /// Right corner: the title sits left of the icon.
    let titleLeading: Bool
    @ViewBuilder var items: () -> Items
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            if titleLeading { titleView }
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .semibold)
                .frame(width: 32, height: 32)
            if !titleLeading { titleView }
        }
        .foregroundStyle(.primary)
        .clipShape(.capsule)
        .glassEffect(.regular, in: .capsule)
        .brightness(hovering ? 0.08 : 0)
        // The menu only takes the click: an AppKit-backed Menu label resizes without animating.
        .overlay {
            Menu(content: items) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(title)
        }
        .fixedSize()
        .onHover { over in withAnimation(.smooth(duration: 0.32)) { hovering = over } }
    }

    @ViewBuilder
    private var titleView: some View {
        if hovering {
            title
                .scaledFont(size: 11, weight: .medium)
                .lineLimit(1)
                .padding(titleLeading ? .leading : .trailing, 12)
                .transition(.opacity.combined(with: .offset(x: titleLeading ? 10 : -10)))
        }
    }
}
