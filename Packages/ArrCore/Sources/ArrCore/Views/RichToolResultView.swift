import SwiftUI

// MARK: - Public entry point

public struct RichToolResultView: View {
    let content: ChatRichContent
    let sonarr: ServiceConfig
    let radarr: ServiceConfig
    let lidarr: ServiceConfig
    let whisparr: ServiceConfig
    let blurWhisparr: Bool

    @State private var visibleCount: Int = Self.pageSize
    private static let pageSize = 10

    public init(content: ChatRichContent, sonarr: ServiceConfig, radarr: ServiceConfig,
                lidarr: ServiceConfig = .empty, whisparr: ServiceConfig = .empty,
                blurWhisparr: Bool = true) {
        self.content = content
        self.sonarr = sonarr
        self.radarr = radarr
        self.lidarr = lidarr
        self.whisparr = whisparr
        self.blurWhisparr = blurWhisparr
    }

    public var body: some View {
        // Two payloads are vertical stacks rather than a bare rail: people (one
        // card per candidate) and a filmography (the person, then their titles).
        // Everything else is the carousel as it was.
        switch content {
        case .people(let people):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(people) { ChatPersonCardView(person: $0) }
            }
        case .cast(let members):
            // The detail surfaces' own cast strip, tap wired to the chat's
            // person route. Its "Cast (N)" header stays — the enclosing tool
            // header only says which tool ran, not what the heads are.
            CastRow(cast: members, onTapPerson: { member in
                if let ref = PersonRef(castMember: member) { PersonRequest.post(ref) }
            })
        case .albums(let artist, _):
            VStack(alignment: .leading, spacing: 4) {
                // Whose albums these are. The tool header names the TOOL, and a
                // rail of covers with no artist above it is a guessing game when
                // the answer covers two artists.
                if let artist, !artist.isEmpty {
                    Text(verbatim: artist)
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                carousel(for: content)
            }
        case .personCredits(let person, let results):
            VStack(alignment: .leading, spacing: 6) {
                ChatPersonCardView(person: person)
                carousel(for: results.first?.source == .sonarr
                         ? .searchSeriesResults(results)
                         : .searchMovieResults(results))
            }
        default:
            carousel(for: content)
        }
    }

    @ViewBuilder
    private func carousel(for content: ChatRichContent) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Eager HStack (not Lazy): with `.fixedSize(vertical:)` on the
            // ScrollView, a LazyHStack only measures the first rendered card, so
            // the row height locked to card #1 and taller later cards got clipped.
            // An eager HStack measures every card up front → height = tallest card.
            // Card counts here are small (bounded by visibleCount), so this is cheap.
            HStack(alignment: .top, spacing: 10) {
                switch content {
                case .searchMovieResults(let results):
                    let visible = Array(results.prefix(visibleCount))
                    ForEach(visible) { r in
                        SearchResultCard(result: r, apiKey: radarr.apiKey)
                    }
                    if visible.count < results.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, results.count)
                        }
                    }
                case .searchSeriesResults(let results):
                    let visible = Array(results.prefix(visibleCount))
                    ForEach(visible) { r in
                        SearchResultCard(result: r, apiKey: sonarr.apiKey)
                    }
                    if visible.count < results.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, results.count)
                        }
                    }
                case .searchArtistResults(let results):
                    let visible = Array(results.prefix(visibleCount))
                    ForEach(visible) { r in
                        SearchResultCard(result: r, apiKey: lidarr.apiKey)
                    }
                    if visible.count < results.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, results.count)
                        }
                    }
                case .searchSceneResults(let results):
                    let visible = Array(results.prefix(visibleCount))
                    ForEach(visible) { r in
                        SearchResultCard(result: r, apiKey: whisparr.apiKey, blurred: blurWhisparr)
                    }
                    if visible.count < results.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, results.count)
                        }
                    }
                case .libraryMovies(let recs):
                    let visible = Array(recs.prefix(visibleCount))
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.title ?? "(untitled)",
                            year: rec.year,
                            hasFile: rec.hasFile ?? false,
                            images: rec.images,
                            baseURL: radarr.baseURL,
                            apiKey: radarr.apiKey,
                            source: .radarr,
                            entityId: rec.id
                        )
                    }
                    if visible.count < recs.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, recs.count)
                        }
                    }
                case .librarySeries(let recs):
                    let visible = Array(recs.prefix(visibleCount))
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.title ?? "(untitled)",
                            year: rec.year,
                            hasFile: nil,
                            images: rec.images,
                            baseURL: sonarr.baseURL,
                            apiKey: sonarr.apiKey,
                            source: .sonarr,
                            entityId: rec.id
                        )
                    }
                    if visible.count < recs.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, recs.count)
                        }
                    }
                case .libraryArtists(let recs):
                    let visible = Array(recs.prefix(visibleCount))
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.artistName ?? "(untitled)",
                            year: nil,
                            hasFile: nil,
                            images: rec.images,
                            baseURL: lidarr.baseURL,
                            apiKey: lidarr.apiKey,
                            source: .lidarr,
                            entityId: rec.id
                        )
                    }
                case .libraryScenes(let recs):
                    let visible = Array(recs.prefix(visibleCount))
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.title ?? "(untitled)",
                            year: rec.year,
                            hasFile: rec.hasFile ?? false,
                            images: rec.images,
                            baseURL: whisparr.baseURL,
                            apiKey: whisparr.apiKey,
                            source: .whisparr,
                            entityId: rec.id,
                            blurred: blurWhisparr
                        )
                    }
                    if visible.count < recs.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, recs.count)
                        }
                    }
                case .calendar(let items):
                    let visible = Array(items.prefix(visibleCount))
                    ForEach(visible) { item in
                        CalendarRowView(item: item, sonarrApiKey: sonarr.apiKey, radarrApiKey: radarr.apiKey,
                                        lidarrApiKey: lidarr.apiKey, whisparrApiKey: whisparr.apiKey,
                                        blurWhisparr: blurWhisparr)
                    }
                    if visible.count < items.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, items.count)
                        }
                    }
                case .downloadQueue(let items):
                    let visible = Array(items.prefix(visibleCount))
                    ForEach(visible) { item in
                        QueueComparisonCard(item: item)
                    }
                    if visible.count < items.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, items.count)
                        }
                    }
                case .albums(_, let albums):
                    let visible = Array(albums.prefix(visibleCount))
                    ForEach(visible) { album in
                        AlbumCard(album: album, baseURL: lidarr.baseURL, apiKey: lidarr.apiKey)
                    }
                    if visible.count < albums.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, albums.count)
                        }
                    }
                case .people, .personCredits, .cast:
                    // Handled a level up as a vertical stack — `carousel(for:)`
                    // is only ever called with the rail-shaped payloads.
                    EmptyView()
                case .discoverSession(let mood, let posterURLs):
                    // Stacked-poster resume widget — tap reopens the
                    // Quiz overlay (live `sessionMatched` count shows
                    // as a "Picked: N" chip).
                    QuizResumeCard(mood: mood, posterURLs: posterURLs)
                }
            }
            .padding(.vertical, 4)
            // No horizontal inset: the rail shares its leading edge with the
            // section header, the person card and the cast strip. Two points of
            // "just a little breathing room" here read as a misalignment,
            // because the neighbouring cards start at zero.
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: content) { _, _ in visibleCount = Self.pageSize }
        #if os(iOS)
        .scrollTargetBehavior(.viewAligned)
        #endif
    }
}

// MARK: - Load-more sentinel

private struct LoadMoreSentinel: View {
    let onAppear: () -> Void
    var body: some View {
        ProgressView()
            .controlSize(.small)
            // Flexible height, never a fixed one: the eager `HStack(alignment:
            // .top)` sizes to its tallest child, so a hard 180pt sentinel *defined*
            // the row height. Harmless next to ~180pt poster cards, but a calendar
            // row's cards are ~76pt — the leftover ~100pt showed up as a dead gap
            // under the carousel. Stretching instead means the sentinel takes the
            // row's natural height rather than dictating it.
            // Leading, not the default centre: a card whose title wraps
            // narrower than 100pt would otherwise float its poster to the
            // right of the column and break the rail's left edge.
            .frame(width: 100, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .center)
            .task { onAppear() }
    }
}

// MARK: - Search result card (has poster URL)

private struct SearchResultCard: View {
    let result: SearchResult
    let apiKey: String
    var blurred: Bool = false

    private var isOwned: Bool { result.inLibraryArrId != nil }

    var body: some View {
        Button(action: handleTap) {
            cardContent
        }
        .buttonStyle(.plain)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                PosterBlurContainer(blurred: blurred, cornerRadius: Tokens.Radius.card) {
                    RemotePoster(
                        url: result.posterURL,
                        apiKey: apiKey,
                        size: CGSize(width: 90, height: 135),
                        cornerRadius: Tokens.Radius.card
                    )
                }
                if isOwned {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .background(Circle().fill(Color.black.opacity(0.5)).padding(-2))
                        .padding(6)
                }
            }
            Text(result.title)
                .scaledFont(size: 12, weight: .semibold)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if let year = result.year {
                    Text(String(year))
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                if let rating = result.rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .scaledFont(size: 9)
                        Text(String(format: "%.1f", rating))
                            .scaledFont(size: 10)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 100, alignment: .leading)
    }

    /// Owned results route to DetailView; missing ones go through the add
    /// flow. The owned check uses `inLibraryArrId` set by the TMDB handlers
    /// when they cross-reference results against the arr library. Missing
    /// items now route to the full `SearchAddPanel` overlay so the user gets
    /// the same hero card + form they'd see if they'd reached the result via
    /// the `+` search flow — SearchAddPanel is the single source of truth.
    private func handleTap() {
        DetailRequest.tap(result)
    }
}

// MARK: - Album card

/// One album in the chat rail. Square art (a sleeve is not a poster), title,
/// year · type, and the two states that matter for a music library: whether
/// every track is on disk, and whether Lidarr is watching for the rest.
/// Tapping opens the album-shaped `DetailView` — the same surface the artist
/// view's album rows push.
private struct AlbumCard: View {
    let album: ChatAlbum
    let baseURL: String
    let apiKey: String

    private var coverURL: URL? { album.images.posterURL(baseURL: baseURL, coverTypes: ["cover", "poster", "disc"]).0 }

    var body: some View {
        Button {
            DetailRequest.post(
                DetailRequest.syntheticItem(
                    source: .lidarr,
                    entityId: album.id,
                    title: album.title,
                    posterURL: coverURL
                )
            )
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    RemotePoster(
                        url: coverURL,
                        apiKey: apiKey,
                        size: CGSize(width: 90, height: 90),
                        cornerRadius: Tokens.Radius.card,
                        fallbackSymbol: "music.note"
                    )
                    if album.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .background(Circle().fill(Color.black.opacity(0.5)).padding(-2))
                            .padding(6)
                    }
                }
                Text(album.title)
                    .scaledFont(size: 12, weight: .semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if let year = album.year {
                        Text(String(year))
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    // Track progress only where it says something the check
                    // doesn't: a partially-grabbed album.
                    if !album.isComplete, let progress = album.trackProgress {
                        Text(verbatim: progress)
                            .scaledFont(size: 10)
                            .foregroundStyle(.secondary)
                    }
                    if !album.monitored {
                        Image(systemName: "bell.slash")
                            .scaledFont(size: 9)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 100, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Library record card (no poster URL — placeholder)

private struct LibraryRecordCard: View {
    let title: String
    let year: Int?
    /// nil for series (they have season/episode statistics, not single-file).
    /// Bool for movies — true = downloaded, false = missing.
    let hasFile: Bool?
    let images: [ArrImage]?
    let baseURL: String
    let apiKey: String
    let source: QueueItem.Source
    let entityId: Int?
    var blurred: Bool = false

    var body: some View {
        Button {
            guard let entityId else { return }
            let url = images?.posterURL(baseURL: baseURL).0
            // `.libraryArtists` cards carry an ARTIST id — open the artist
            // surface, not the album-shaped DetailView.
            if source == .lidarr {
                DetailRequest.post(
                    DetailRequest.syntheticArtistItem(
                        artistId: entityId,
                        name: title,
                        posterURL: url
                    )
                )
                return
            }
            DetailRequest.post(
                DetailRequest.syntheticItem(
                    source: source,
                    entityId: entityId,
                    title: title,
                    posterURL: url
                )
            )
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .disabled(entityId == nil)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                PosterBlurContainer(blurred: blurred, cornerRadius: Tokens.Radius.card) {
                    RemotePoster(
                        url: images?.posterURL(baseURL: baseURL).0,
                        apiKey: apiKey,
                        size: CGSize(width: 90, height: 135),
                        cornerRadius: Tokens.Radius.card
                    )
                }
                if let hasFile {
                    Image(systemName: hasFile ? "checkmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(hasFile ? .green : .orange)
                        .background(Circle().fill(Color.black.opacity(0.5)).padding(-2))
                        .padding(6)
                }
            }
            Text(title)
                .scaledFont(size: 12, weight: .semibold)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let year {
                Text(String(year))
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 100, alignment: .leading)
    }
}

// MARK: - Calendar row

private struct CalendarRowView: View {
    let item: UpcomingItem
    let sonarrApiKey: String
    let radarrApiKey: String
    let lidarrApiKey: String
    var whisparrApiKey: String = ""
    var blurWhisparr: Bool = false

    private var effectivelyBlurred: Bool {
        item.source == .whisparr && blurWhisparr
    }

    private var apiKey: String {
        switch item.source {
        case .sonarr: return sonarrApiKey
        case .radarr: return radarrApiKey
        case .lidarr: return lidarrApiKey
        case .whisparr: return whisparrApiKey
        }
    }

    var body: some View {
        Button {
            guard let entityId = item.entityId else { return }
            DetailRequest.post(
                DetailRequest.syntheticItem(
                    source: item.source,
                    entityId: entityId,
                    title: item.title,
                    posterURL: item.posterURL,
                    posterRequiresAuth: item.posterRequiresAuth
                )
            )
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .disabled(item.entityId == nil)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 8) {
            PosterBlurContainer(blurred: effectivelyBlurred, cornerRadius: Tokens.Radius.chip) {
                RemotePoster(
                    url: item.posterURL,
                    apiKey: item.posterRequiresAuth ? apiKey : nil,
                    tier: .icon,
                    size: CGSize(width: 40, height: 60),
                    cornerRadius: Tokens.Radius.chip
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.dateLabel(item.airDate))
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .scaledFont(size: 12, weight: .semibold)
                    .lineLimit(2)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .scaledFont(size: 11)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 200, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .contentShape(Rectangle())
    }

    private static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
