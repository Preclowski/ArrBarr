import SwiftUI
import ArrCore

/// Which row of Discover, as a navigation value: what a shelf heading pushes
/// and what the section page draws. The kind travels with it — a genre row
/// opened from Series is a page of series genres.
public enum DiscoverSection: Hashable, Sendable {
    case genres(MediaType)
    case awards
    case lists
    case decades(MediaType)

    var title: String {
        switch self {
        case .genres: return String(localized: "Genres", bundle: .module)
        case .awards: return String(localized: "Awarded", bundle: .module)
        case .lists: return String(localized: "Lists", bundle: .module)
        case .decades: return String(localized: "Decades", bundle: .module)
        }
    }

    /// The width its tiles are drawn at, in the shelf and in the grid alike.
    var tileWidth: CGFloat {
        switch self {
        case .genres, .lists: return TileSize.wide
        case .awards: return TileSize.widest
        case .decades: return TileSize.narrow
        }
    }
}

/// The Discover section: the four ways into TMDB that are not "everything",
/// as four shelves of tiles — genres, awards, public lists, decades. Each
/// tile opens a library view (the same grid/table the Movies and Series
/// sections draw), and each heading opens its whole row as a page: a row can
/// be scrolled through or opened and picked from.
///
/// It replaces three sidebar tabs (Genres, Awarded, Lists) that were each one
/// wall of cards with its own chrome, its own loader and its own idea of what
/// a card looks like — those walls are now the one `DiscoverSectionView`.
struct DiscoverView: View {
    @EnvironmentObject private var config: TonightConfig
    @ObservedObject private var art = DiscoverArt.shared
    /// Genres and decades are per kind; awards and public lists are not.
    @State private var type: MediaType = .movie

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                shelf(.genres(type))
                shelf(.awards)
                shelf(.lists)
                shelf(.decades(type))
            }
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
        // The page opens at its first row. (Each shelf states its own
        // leading anchor — see `CardShelf`.)
        .defaultScrollAnchor(.top)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .task(id: config.tmdbApiKey) { await art.load(config: config) }
    }

    private var header: some View {
        HStack {
            GlassSegmentedPicker(selection: $type, options: [
                (.movie, String(localized: "Movies", bundle: .module)),
                (.tv, String(localized: "Series", bundle: .module)),
            ])
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, pageChromeTop)
        .padding(.bottom, 10)
        .background(.bar)
    }

    /// One row. What is in it and what a tile looks like is the section's
    /// business (`DiscoverTiles`), so the shelf here and the grid on the
    /// section page cannot drift apart.
    @ViewBuilder
    private func shelf(_ section: DiscoverSection) -> some View {
        switch section {
        case .genres(let type):
            CardShelf(title: section.title, items: Genres.refs(for: type),
                      cardWidth: section.tileWidth, destination: section) {
                DiscoverTiles.genre($0)
            }
        case .awards:
            CardShelf(title: section.title, items: Awards.all,
                      cardWidth: section.tileWidth, destination: section) {
                DiscoverTiles.award($0, art: art)
            }
        case .lists:
            CardShelf(title: section.title, items: art.lists,
                      cardWidth: section.tileWidth, destination: section) {
                DiscoverTiles.list($0, art: art)
            }
        case .decades(let type):
            CardShelf(title: section.title, items: Decades.refs(for: type),
                      cardWidth: section.tileWidth, destination: section) {
                DiscoverTiles.decade($0)
            }
        }
    }
}

/// One row opened whole: the same tiles the shelf holds, in a grid that wraps
/// instead of scrolling sideways.
struct DiscoverSectionView: View {
    let section: DiscoverSection

    @EnvironmentObject private var config: TonightConfig
    @ObservedObject private var art = DiscoverArt.shared

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                switch section {
                case .genres(let type):
                    ForEach(Genres.refs(for: type)) { DiscoverTiles.genre($0) }
                case .awards:
                    ForEach(Awards.all) { DiscoverTiles.award($0, art: art) }
                case .lists:
                    ForEach(art.lists) { DiscoverTiles.list($0, art: art) }
                case .decades(let type):
                    ForEach(Decades.refs(for: type)) { DiscoverTiles.decade($0) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .pushedPage()
        .task(id: config.tmdbApiKey) { await art.load(config: config) }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: section.tileWidth,
                            maximum: section.tileWidth + 60),
                  spacing: 20, alignment: .top)]
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackButton()
            Text(section.title).font(.headline)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, pageChromeTop)
        .padding(.bottom, 10)
        .background(.bar)
    }
}

// MARK: - The tiles

/// Every Discover tile, in one place: the shelf on the section index and the
/// grid on a section's own page draw these same four, so a tile can never
/// look like one thing in a row and another in a grid.
@MainActor
enum DiscoverTiles {
    static func genre(_ ref: GenreRef) -> some View {
        NavigationLink(value: ref) {
            DiscoverTile(title: ref.displayName, width: TileSize.wide) {
                HashArtwork(seed: "genre-\(ref.id)",
                            symbol: Genres.symbol(for: ref.id, type: ref.type))
            }
        }
        .buttonStyle(.plain)
    }

    static func decade(_ ref: DecadeRef) -> some View {
        NavigationLink(value: ref) {
            DiscoverTile(title: ref.displayName, width: TileSize.narrow) {
                HashArtwork(seed: "decade-\(ref.start)",
                            glyph: String(String(ref.start).suffix(2)))
            }
        }
        .buttonStyle(.plain)
    }

    /// The award catalog is a movie one — the prizes it holds have no series
    /// counterpart — so this row stands whichever kind the page is on.
    static func award(_ award: Award, art: DiscoverArt) -> some View {
        NavigationLink(value: AwardRef(awardId: award.id)) {
            DiscoverTile(title: award.displayName,
                         subtitle: award.displayCategory,
                         footnote: "\(String(award.years.lowerBound))–\(String(award.years.upperBound))",
                         symbol: award.symbol,
                         width: TileSize.widest) {
                PosterStrip(items: art.award(award), fallback: .indigo)
            }
        }
        .buttonStyle(.plain)
    }

    static func list(_ ref: TMDBListRef, art: DiscoverArt) -> some View {
        NavigationLink(value: ref) {
            DiscoverTile(title: ref.name,
                         subtitle: String(format: String(localized: "%d titles", bundle: .module),
                                          ref.itemCount),
                         brand: "tmdb",
                         width: TileSize.wide) {
                PosterStrip(items: art.list(ref), fallback: .teal)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The tile

/// The tile geometry, shared by the rows and the tile itself: three widths
/// so the shelves read as one family, and one height for every tile in the
/// section.
enum TileSize {
    static let narrow: CGFloat = 200
    static let wide: CGFloat = 280
    static let widest: CGFloat = 340
    static let height: CGFloat = 150
}

/// One Discover tile: a strip of artwork under a scrim, with the name over
/// it. Every row draws this same shape — only its width and what it puts
/// behind the glass differ.
///
/// The width is fixed by the row rather than adaptive. The awards used to sit
/// in an adaptive grid, and between two column counts the ceremony names
/// wrapped to two and three lines and stopped reading as names at all; a
/// shelf of fixed tiles cannot get there.
struct DiscoverTile<Background: View>: View {
    let title: String
    var subtitle: String? = nil
    /// A quiet third line, bottom-right (an award's span of years).
    var footnote: String? = nil
    /// SF Symbol drawn before the title (the award's own mark).
    var symbol: String? = nil
    /// A brand mark drawn in the corner instead (TMDB, for a public list).
    var brand: String? = nil
    let width: CGFloat
    @ViewBuilder let background: Background

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            background
                .frame(width: width, height: TileSize.height)
                .clipped()
                .overlay(BackdropScrim().opacity(0.95))
                // The name has to read over whatever art landed here, so the
                // bottom half gets its own dedicated wash.
                .overlay(LinearGradient(stops: [
                    .init(color: .clear, location: 0.3),
                    .init(color: .black.opacity(0.8), location: 1),
                ], startPoint: .top, endPoint: .bottom))
                // …and a wash in from the leading edge, where the name and
                // everything under it starts. Three posters side by side are
                // busy enough that a bottom-up scrim alone left award names
                // sitting on somebody's face.
                .overlay(LinearGradient(stops: [
                    .init(color: .black.opacity(0.65), location: 0),
                    .init(color: .clear, location: 0.75),
                ], startPoint: .leading, endPoint: .trailing))
                .overlay(Color.black.opacity(hovering ? 0.05 : 0.18))

            if let brand {
                BrandMark(name: brand, height: 12)
                    .frame(width: 34)
                    .padding(12)
                    .frame(width: width, height: TileSize.height, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text(title)
                        .font(.title3.weight(.bold))
                        // Two lines at most, and never a third: a long list
                        // name truncates rather than eating the tile.
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } icon: {
                    if let symbol { Image(systemName: symbol) }
                }
                .labelStyle(TileLabelStyle())
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .opacity(0.85)
                        .lineLimit(1)
                }
                if let footnote {
                    Text(footnote)
                        .font(.caption.monospacedDigit())
                        .opacity(0.65)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 5)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, height: TileSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(hovering ? 0.35 : 0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(hovering ? 0.35 : 0.18),
                radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
    }
}

/// Symbol and title on one baseline, with the title free to wrap under
/// itself rather than under the symbol.
private struct TileLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// Generated tile art: a gradient whose hue is fixed by a hash of what the
/// tile stands for, with the genre's mark — or the decade's own two digits —
/// sitting large and faint behind the name.
///
/// Genres and decades used to borrow three posters each, which meant a dozen
/// requests before the page could look like anything and the same handful of
/// popular films turning up behind four different genres. A generated cover
/// is instant, never repeats itself, and is the same every launch: the hash
/// is FNV-1a, not `Hashable`, whose seed changes with every run.
struct HashArtwork: View {
    let seed: String
    /// SF Symbol drawn faintly behind the name (a genre's mark).
    var symbol: String? = nil
    /// Two big digits instead of a symbol (a decade).
    var glyph: String? = nil

    private var hue: Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        // Through the golden angle, so seeds one character apart (2010s,
        // 2020s) land on opposite sides of the wheel instead of three
        // neighbouring greens.
        let step = Double(hash % 997) * 0.6180339887498949
        return step - step.rounded(.down)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            LinearGradient(colors: [
                Color(hue: hue, saturation: 0.52, brightness: 0.58),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1),
                      saturation: 0.85, brightness: 0.20),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)

            mark
                .foregroundStyle(.white.opacity(0.20))
                .rotationEffect(.degrees(-8))
                .padding(.trailing, 18)
                .shadow(color: .black.opacity(0.25), radius: 8)
        }
    }

    @ViewBuilder
    private var mark: some View {
        if let glyph {
            Text(glyph)
                .font(.system(size: 96, weight: .heavy, design: .rounded))
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 68, weight: .semibold))
        }
    }
}

/// The art behind a tile: up to three posters side by side, or a flat wash
/// when there is nothing to show yet.
struct PosterStrip: View {
    let items: [MediaItem]
    var fallback: Color = .gray

    var body: some View {
        if items.isEmpty {
            LinearGradient(colors: [fallback.opacity(0.7), .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    if index < items.count {
                        RemoteImage(url: items[index].displayPosterURL)
                            .frame(maxWidth: .infinity)
                    } else {
                        Rectangle().fill(.quaternary).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

// MARK: - Artwork

/// The two rows that are made of real titles: the awards' recent winners and
/// the public lists themselves. Genres and decades generate their own covers
/// and ask TMDB for nothing.
///
/// Art is a nice-to-have: every tile is a working link before a single
/// poster lands, so each row fills itself in as its own fetch returns rather
/// than the page waiting on a spinner.
@MainActor
final class DiscoverArt: ObservableObject {
    /// One catalog for the whole section: opening a row as its own page must
    /// not refetch what the index already has.
    static let shared = DiscoverArt()

    /// award id → the posters of its most recent winners.
    @Published private var awards: [String: [MediaItem]] = [:]
    @Published private(set) var lists: [TMDBListRef] = []
    @Published private var listArt: [Int: [MediaItem]] = [:]

    private var loaded: Set<String> = []

    func award(_ award: Award) -> [MediaItem] { awards[award.id] ?? [] }
    func list(_ ref: TMDBListRef) -> [MediaItem] { listArt[ref.id] ?? [] }

    func load(config: TonightConfig) async {
        guard !config.tmdbApiKey.isEmpty else { return }
        let tmdb = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in await self.loadAwards(tmdb) }
            group.addTask { @MainActor in await self.loadLists(tmdb) }
        }
    }

    /// Once per kind: the fetch is the same every time and the tiles are not
    /// worth a second round of it.
    private func once(_ key: String) -> Bool { loaded.insert(key).inserted }

    /// Three recent winners per award — enough to give every tile a face.
    private func loadAwards(_ tmdb: TMDBService) async {
        guard once("awards") else { return }
        await withTaskGroup(of: (String, [MediaItem]).self) { group in
            for award in Awards.all {
                group.addTask {
                    var items: [MediaItem] = []
                    for winner in award.winners(decade: nil).prefix(3) {
                        if let match = try? await tmdb.movieMatch(title: winner.title, year: winner.year),
                           match.posterPath != nil {
                            items.append(match)
                        }
                    }
                    return (award.id, items)
                }
            }
            for await (id, items) in group { awards[id] = items }
        }
    }

    /// The public lists the row is made of: the featured anchors first, then
    /// what the community keeps around today's trending titles. TMDB exposes
    /// no list search, so this is the whole catalog there is.
    private func loadLists(_ tmdb: TMDBService) async {
        guard once("lists") else { return }
        // Anchors resolve individually so one dead id can't sink the rest.
        // One `/list/{id}` call answers with the name AND the contents, so
        // the anchors' tiles get their art for nothing.
        for id in TMDBService.featuredListIds {
            guard let (ref, items) = try? await tmdb.list(id: id) else { continue }
            lists.append(ref)
            listArt[ref.id] = art(from: items)
        }
        let popular = (try? await tmdb.popularLists(
            excluding: Set(TMDBService.featuredListIds))) ?? []
        lists += popular
        // The aggregation only knows names and sizes, so art for these costs
        // a call each — worth it for the tiles in view, not for all 18.
        for ref in popular.prefix(6) {
            guard let items = try? await tmdb.listItems(listId: ref.id) else { continue }
            listArt[ref.id] = art(from: items)
        }
    }

    /// The first three titles that actually have a poster.
    private func art(from items: [MediaItem]) -> [MediaItem] {
        Array(items.filter { $0.posterPath != nil }.prefix(3))
    }
}
