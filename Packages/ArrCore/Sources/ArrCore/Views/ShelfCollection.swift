import SwiftUI
import MediaKit

/// What the Roulette spins: the arr's library, or a TMDB list.
enum ShelfCollection: String, CaseIterable, Identifiable {
    case library, popular, trending, topRated, inCinemas

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .library: "shelf.collection.library"
        case .popular: "shelf.collection.popular"
        case .trending: "shelf.collection.trending"
        case .topRated: "shelf.collection.topRated"
        case .inCinemas: "shelf.collection.inCinemas"
        }
    }

    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .popular: "flame"
        case .trending: "chart.line.uptrend.xyaxis"
        case .topRated: "trophy"
        case .inCinemas: "popcorn"
        }
    }

    var isRemote: Bool { self != .library }

    /// Cinemas are movies only; TMDB lists need a TMDB key.
    static func available(for source: QueueItem.Source, tmdbConfigured: Bool) -> [ShelfCollection] {
        guard tmdbConfigured else { return [.library] }
        let lists: [ShelfCollection] = [.library, .popular, .trending, .topRated]
        return source == .sonarr ? lists : lists + [.inCinemas]
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
    /// Trending past a hundred is noise; the ranked lists stay meaningful for longer.
    private static let pages = 10
    private static let trendingPages = 5
    private(set) var failed: Set<Key> = []

    func load(_ key: Key, configStore: ConfigStore) async {
        guard items[key] == nil else { return }
        failed.remove(key)
        let client = configStore.tmdbClient
        do {
            switch (key.collection, key.source) {
            case (.library, _):
                return
            case (_, .sonarr):
                let shows = switch key.collection {
                case .trending: try await client.trendingSeries(pages: Self.trendingPages)
                case .topRated: try await client.topRatedSeries(pages: Self.pages)
                default: try await client.popularSeries(pages: Self.pages)
                }
                let owned = await ArrLibraryMaps.sonarrByTMDBId(config: configStore.sonarr)
                items[key] = zip(shows, TMDBSearchMapping.series(shows, libraryMap: owned)).map {
                    ShelfRemoteItem(result: $1, tmdbId: $0.id, releaseDate: $0.firstAirDate)
                }
            default:
                let movies = switch key.collection {
                case .trending: try await client.trendingMovies(pages: Self.trendingPages)
                case .topRated: try await client.topRatedMovies(pages: Self.pages)
                // The user's country, not the app language: "in cinemas" is a place.
                case .inCinemas: try await client.moviesInCinemas(region: Locale.current.region?.identifier)
                default: try await client.popularMovies(pages: Self.pages)
                }
                let owned = await ArrLibraryMaps.radarrByTMDBId(config: configStore.radarr)
                items[key] = zip(movies, TMDBSearchMapping.movies(movies, libraryMap: owned)).map {
                    ShelfRemoteItem(result: $1, tmdbId: $0.id, releaseDate: $0.releaseDate)
                }
            }
        } catch {
            failed.insert(key)
        }
    }
}

/// Every collection the Roulette can spin.
struct ShelfCollectionPanel: View {
    @Binding var collection: ShelfCollection
    let available: [ShelfCollection]
    /// Titles in the arr's library for the current source.
    let libraryCount: Int?
    @State private var hovered: ShelfCollection?
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 2) {
            ForEach(available) { c in
                let on = c == collection
                Button { collection = c } label: {
                    HStack(spacing: 8) {
                        Image(systemName: c.symbol)
                            .scaledFont(size: 11.5)
                            .foregroundStyle(on ? .primary : .secondary)
                            .frame(width: 16)
                        Text(c.title, bundle: .module)
                            .scaledFont(size: 12, weight: on ? .medium : .regular)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Group {
                            if c == .library, let libraryCount { Text(libraryCount, format: .number) } else if c.isRemote { Text(verbatim: "TMDB") }
                        }
                        .scaledFont(size: 10.5)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.white.opacity(0.14))
                                .matchedGeometryEffect(id: "selection", in: selection)
                        } else if hovered == c {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = c } else if hovered == c { hovered = nil }
                }
            }
        }
        .frame(minWidth: 190)
        .animation(.spring(response: 0.38, dampingFraction: 0.75), value: collection)
    }
}
