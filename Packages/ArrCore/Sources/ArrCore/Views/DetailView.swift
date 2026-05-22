import SwiftUI

/// Detail view for a queue item — replaces the popover content while shown.
/// Fetches data from Radarr/Sonarr/Lidarr based on `item.entityId` and
/// `item.source`, then renders a service-specific layout.
public struct DetailView: View {
    let item: QueueItem
    let onBack: () -> Void
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore

    /// All queue items belonging to the same arr entity (movie/series/album).
    /// One item → render the single-item form; multiple → stacked list with
    /// the originally-clicked row highlighted.
    private var siblings: [QueueItem] {
        let pool: [QueueItem] = switch item.source {
        case .radarr: viewModel.radarr
        case .sonarr: viewModel.sonarr
        case .lidarr: viewModel.lidarr
        }
        guard let id = item.entityId else { return [item] }
        let matched = pool.filter { $0.entityId == id }
        return matched.isEmpty ? [item] : matched
    }

    @State private var radarrDetail: RadarrMovieDetail?
    @State private var sonarrDetail: SonarrSeriesDetail?
    @State private var sonarrEpisodes: [SonarrEpisodeDetail] = []
    @State private var lidarrAlbum: LidarrAlbumDetail?
    @State private var lidarrTracks: [LidarrTrackDetail] = []
    @State private var loading = true
    @State private var loadError: String?

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) { await load() }
    }

    // MARK: - Header (back button + safari)

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Image(systemName: item.source.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(item.source.displayName)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            if let url = webURL {
                Button {
                    PlatformURLOpener.open(url)
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Open in browser", bundle: .module))
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content switch

    @ViewBuilder
    private var content: some View {
        if loading {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .padding(.vertical, 60)
        } else {
            switch item.source {
            case .radarr: radarrContent
            case .sonarr: sonarrContent
            case .lidarr: lidarrContent
            }
        }
    }

    // MARK: - Radarr

    @ViewBuilder
    private var radarrContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerCard(
                title: radarrDetail?.title ?? item.title,
                year: radarrDetail?.year,
                runtime: radarrDetail?.runtime,
                genres: radarrDetail?.genres ?? [],
                certification: radarrDetail?.certification,
                ratings: radarrRatingChips,
                existingTrailer: nil,
                posterUrl: posterURL(images: radarrDetail?.images),
                fallbackSymbol: "film",
                posterAspect: 2.0/3.0
            )

            if item.isUpgrade {
                ExistingFileBanner(item: item)
            }

            if let overview = radarrDetail?.overview, !overview.isEmpty {
                ExpandableOverview(text: overview)
            }

            DownloadSection(
                items: siblings,
                focused: item,
                showInlineUpgrade: false,
                showCustomFormats: true,
                showListingBadges: true
            )

            if let err = loadError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var radarrRatingChips: [RatingChip] {
        guard let r = radarrDetail?.ratings else { return [] }
        var chips: [RatingChip] = []
        if let v = r.imdb?.value { chips.append(RatingChip(label: "IMDb", value: String(format: "%.1f", v), color: .yellow)) }
        if let v = r.tmdb?.value { chips.append(RatingChip(label: "TMDB", value: String(format: "%.1f", v), color: .teal)) }
        if let v = r.rottenTomatoes?.value { chips.append(RatingChip(label: "RT", value: "\(Int(v))%", color: .red)) }
        if let v = r.metacritic?.value { chips.append(RatingChip(label: "MC", value: "\(Int(v))", color: .green)) }
        return chips
    }

    // MARK: - Sonarr

    @ViewBuilder
    private var sonarrContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerCard(
                title: sonarrDetail?.title ?? item.title,
                year: sonarrDetail?.year,
                runtime: sonarrDetail?.runtime,
                genres: sonarrDetail?.genres ?? [],
                certification: sonarrDetail?.network,
                ratings: sonarrRatingChips,
                existingTrailer: nil,
                posterUrl: posterURL(images: sonarrDetail?.images),
                fallbackSymbol: "tv",
                posterAspect: 2.0/3.0
            )

            if let overview = sonarrDetail?.overview, !overview.isEmpty {
                ExpandableOverview(text: overview)
            }

            if let seasons = sonarrDetail?.seasons, !seasons.isEmpty {
                Text("Seasons")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                ForEach(seasons.filter { $0.seasonNumber > 0 }, id: \.seasonNumber) { season in
                    SeasonRow(
                        season: season,
                        episodes: sonarrEpisodes.filter { $0.seasonNumber == season.seasonNumber }
                    )
                }
                Divider().padding(.vertical, 2)
            }

            DownloadSection(
                items: siblings,
                focused: item,
                showInlineUpgrade: true,
                showCustomFormats: true,
                rowHoverDetail: true,
                listCollapsible: true,
                listExpandedDefault: false
            )

            if let err = loadError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var sonarrRatingChips: [RatingChip] {
        guard let r = sonarrDetail?.ratings, let v = r.value else { return [] }
        return [RatingChip(label: "Rating", value: String(format: "%.1f", v), color: .yellow)]
    }

    // MARK: - Lidarr

    @ViewBuilder
    private var lidarrContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            lidarrHeaderCard
            if let overview = lidarrAlbum?.overview, !overview.isEmpty {
                ExpandableOverview(text: overview)
            }

            DownloadSection(items: siblings, focused: item)

            if !lidarrTracks.isEmpty {
                Divider().padding(.vertical, 2)
                Text("Tracks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                let mediums = Dictionary(grouping: lidarrTracks, by: { $0.mediumNumber ?? 1 })
                    .sorted { $0.key < $1.key }
                ForEach(mediums, id: \.key) { medium, tracks in
                    if mediums.count > 1 {
                        Text("Disc \(medium)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                    ForEach(tracks.sorted(by: { ($0.absoluteTrackNumber ?? 0) < ($1.absoluteTrackNumber ?? 0) })) { track in
                        TrackRow(track: track)
                    }
                }
            }
            if let err = loadError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var lidarrHeaderCard: some View {
        let album = lidarrAlbum
        let posterUrl = posterURL(images: album?.images) ?? posterURL(images: album?.artist?.images)
        return HStack(alignment: .top, spacing: 12) {
            RemotePoster(
                url: posterUrl ?? item.posterURL,
                apiKey: item.posterRequiresAuth ? configStore.lidarr.apiKey : nil,
                size: CGSize(width: 110, height: 110),
                cornerRadius: 6,
                fallbackSymbol: "music.note"
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(album?.title ?? item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                if let artist = album?.artist?.artistName {
                    Text(artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let year = lidarrYear {
                        Text(year).foregroundStyle(.secondary)
                    }
                    if let type = album?.albumType, !type.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(type).foregroundStyle(.secondary)
                    }
                    if let stats = album?.statistics, let count = stats.totalTrackCount, count > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(count) tracks").foregroundStyle(.secondary)
                    }
                    if let dur = album?.duration, dur > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text(formatDuration(ms: dur)).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                if !lidarrGenres.isEmpty {
                    GenreChips(genres: lidarrGenres)
                }
                if let r = album?.ratings, let v = r.value, v > 0 {
                    HStack(spacing: 6) {
                        RatingPill(chip: RatingChip(label: "Rating", value: String(format: "%.1f", v), color: .yellow))
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var lidarrYear: String? {
        guard let dateStr = lidarrAlbum?.releaseDate, let date = parseArrDate(dateStr) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy"
        return f.string(from: date)
    }

    private var lidarrGenres: [String] { lidarrAlbum?.genres ?? [] }

    // MARK: - Shared header card

    @ViewBuilder
    private func headerCard(
        title: String,
        year: Int?,
        runtime: Int?,
        genres: [String],
        certification: String?,
        ratings: [RatingChip],
        existingTrailer: QueueItem?,
        posterUrl: URL?,
        fallbackSymbol: String,
        posterAspect: CGFloat
    ) -> some View {
        MediaHeaderCard(
            title: title,
            year: year,
            runtime: runtime,
            network: nil,
            certification: certification,
            genres: genres,
            ratings: ratings,
            posterURL: posterUrl ?? item.posterURL,
            posterRequiresAuth: item.posterRequiresAuth,
            apiKey: apiKeyForSource,
            fallbackSymbol: fallbackSymbol,
            posterAspect: posterAspect,
            trailing: existingTrailer.map { AnyView(ExistingFileLine(item: $0)) }
        )
    }

    // MARK: - Helpers

    private var apiKeyForSource: String? {
        switch item.source {
        case .radarr: return configStore.radarr.apiKey
        case .sonarr: return configStore.sonarr.apiKey
        case .lidarr: return configStore.lidarr.apiKey
        }
    }

    private var webURL: URL? {
        guard let slug = item.contentSlug else { return nil }
        let (cfg, path): (ServiceConfig, String) = switch item.source {
        case .radarr: (configStore.radarr, "/movie/\(slug)")
        case .sonarr: (configStore.sonarr, "/series/\(slug)")
        case .lidarr: (configStore.lidarr, "/album/\(slug)")
        }
        return URL(string: cfg.baseURL)?.appendingPathComponent(path)
    }

    private func posterURL(images: [ArrImage]?) -> URL? {
        let baseURL: String = switch item.source {
        case .radarr: configStore.radarr.baseURL
        case .sonarr: configStore.sonarr.baseURL
        case .lidarr: configStore.lidarr.baseURL
        }
        let (url, _) = (images?.posterURL(baseURL: baseURL, coverTypes: ["poster", "cover"]) ?? (nil, false))
        return url
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        guard let entityId = item.entityId else {
            loadError = "No entity id"
            return
        }
        do {
            switch item.source {
            case .radarr:
                let client = RadarrClient(config: configStore.radarr)
                radarrDetail = try await client.fetchMovieDetails(id: entityId)
            case .sonarr:
                let client = SonarrClient(config: configStore.sonarr)
                async let d = client.fetchSeriesDetails(id: entityId)
                async let eps = client.fetchEpisodes(seriesId: entityId)
                sonarrDetail = try await d
                sonarrEpisodes = try await eps
            case .lidarr:
                let client = LidarrClient(config: configStore.lidarr)
                async let a = client.fetchAlbumDetails(id: entityId)
                async let ts = client.fetchTracks(albumId: entityId)
                lidarrAlbum = try await a
                lidarrTracks = try await ts
            }
        } catch {
            loadError = "Couldn't load details: \(error.localizedDescription)"
        }
    }
}

// MARK: - Pieces

public struct RatingChip {
    let label: String
    let value: String
    let color: Color
}

/// Shared header card used by the queue detail view and the search add
/// panel. Right column scales by what's provided — every field is optional
/// so each caller passes only the data its source can supply.
public struct MediaHeaderCard: View {
    let title: String
    var subtitle: String? = nil
    var year: Int? = nil
    var runtime: Int? = nil
    var network: String? = nil
    var certification: String? = nil
    var genres: [String] = []
    var ratings: [RatingChip] = []
    let posterURL: URL?
    var posterRequiresAuth: Bool = false
    var apiKey: String? = nil
    var fallbackSymbol: String = "film"
    var posterAspect: CGFloat = 2.0/3.0
    var trailing: AnyView? = nil

    public var body: some View {
        let posterWidth: CGFloat = 110
        let posterHeight = posterWidth / posterAspect
        HStack(alignment: .top, spacing: 12) {
            RemotePoster(
                url: posterURL,
                apiKey: posterRequiresAuth ? apiKey : nil,
                size: CGSize(width: posterWidth, height: posterHeight),
                cornerRadius: 6,
                fallbackSymbol: fallbackSymbol
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(3)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let year { Text(verbatim: String(year)).foregroundStyle(.secondary) }
                    if let runtime, runtime > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(runtime) min").foregroundStyle(.secondary)
                    }
                    if let network, !network.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(network).foregroundStyle(.secondary)
                    }
                    if let cert = certification, !cert.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(cert).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                if !genres.isEmpty {
                    GenreChips(genres: genres)
                }
                if !ratings.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(ratings, id: \.label) { RatingPill(chip: $0) }
                    }
                    .padding(.top, 2)
                }
                if let trailing {
                    trailing
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct RatingPill: View {
    let chip: RatingChip
    public var body: some View {
        HStack(spacing: 3) {
            Text(chip.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(chip.color)
            Text(chip.value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(chip.color.opacity(0.15), in: Capsule())
    }
}

private struct GenreChips: View {
    let genres: [String]
    public var body: some View {
        TooltipFlowLayout(spacing: 4) {
            ForEach(genres, id: \.self) { g in
                Text(g)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
        }
        .padding(.top, 2)
    }
}

/// Custom-format tag chips with optional score, wrapping to multiple lines
/// when needed. Used in the detail download section to mirror the chip strip
/// shown on listing rows.
private struct CustomFormatChips: View {
    let formats: [String]
    let score: Int
    public var body: some View {
        TooltipFlowLayout(spacing: 4) {
            ForEach(formats, id: \.self) { TagChip(text: $0) }
            if score != 0 {
                let sign = score > 0 ? "+" : ""
                TagChip(text: "\(sign)\(score)", color: score > 0 ? .green : .red)
            }
        }
    }
}

public struct ExpandableOverview: View {
    let text: String
    @State private var expanded = false
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            if !expanded && text.count > 220 {
                Button {
                    withAnimation(.smooth(duration: 0.18)) { expanded = true }
                } label: {
                    Text("Show more")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SeasonRow: View {
    let season: SonarrSeasonInfo
    let episodes: [SonarrEpisodeDetail]
    @State private var expanded = false

    private var stats: SonarrSeasonStats? { season.statistics }
    private var have: Int { stats?.episodeFileCount ?? 0 }
    private var total: Int { stats?.totalEpisodeCount ?? stats?.episodeCount ?? 0 }
    private var pct: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(have) / Double(total))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(String(format: "Season %02d", season.seasonNumber))
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primary.opacity(0.10))
                            RoundedRectangle(cornerRadius: 1)
                                .fill(have == total && total > 0 ? Color.green : Color.accentColor)
                                .frame(width: geo.size.width * pct)
                        }
                    }
                    .frame(width: 60, height: 3)
                    Text("\(have)/\(total)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(episodes.sorted(by: { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) })) { ep in
                        EpisodeRow(episode: ep)
                    }
                }
                .padding(.leading, 0)
                .padding(.trailing, 4)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct EpisodeRow: View {
    let episode: SonarrEpisodeDetail
    public var body: some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", episode.episodeNumber ?? 0))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .leading)
            Text(episode.title ?? "—")
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            if let air = episode.airDateUtc.flatMap(parseArrDate) {
                Text(Self.formatter.string(from: air))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: episode.hasFile == true ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(episode.hasFile == true ? Color.green : Color.secondary.opacity(0.5))
        }
    }
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none
        return f
    }()
}

private struct TrackRow: View {
    let track: LidarrTrackDetail
    public var body: some View {
        HStack(spacing: 6) {
            Text(track.trackNumber ?? String(track.absoluteTrackNumber ?? 0))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .leading)
            Text(track.title ?? "—")
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            if let dur = track.duration, dur > 0 {
                Text(formatDuration(ms: dur))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: track.hasFile == true ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(track.hasFile == true ? Color.green : Color.secondary.opacity(0.5))
        }
    }
}

/// "Option B" download section: minimalist, no card chrome.
///
/// - Single item: one progress line + thin bar; if upgrade, a NEW/OLD
///   two-line diff and a monospaced release-name footer.
/// - Multiple items (ungrouped episodes for the same series): a header line
///   summarising the queue, then a stacked list of compact rows. The
///   originally-clicked row gets an accent left border so the user keeps
///   their bearings.
private struct DownloadSection: View {
    let items: [QueueItem]
    let focused: QueueItem
    var showInlineUpgrade: Bool = true
    var showCustomFormats: Bool = false
    var showListingBadges: Bool = false
    var rowHoverDetail: Bool = false
    var listCollapsible: Bool = false
    var listExpandedDefault: Bool = true

    @State private var listExpanded: Bool

    init(
        items: [QueueItem],
        focused: QueueItem,
        showInlineUpgrade: Bool = true,
        showCustomFormats: Bool = false,
        showListingBadges: Bool = false,
        rowHoverDetail: Bool = false,
        listCollapsible: Bool = false,
        listExpandedDefault: Bool = true
    ) {
        self.items = items
        self.focused = focused
        self.showInlineUpgrade = showInlineUpgrade
        self.showCustomFormats = showCustomFormats
        self.showListingBadges = showListingBadges
        self.rowHoverDetail = rowHoverDetail
        self.listCollapsible = listCollapsible
        self.listExpandedDefault = listExpandedDefault
        self._listExpanded = State(initialValue: listExpandedDefault)
    }

    private var sortedItems: [QueueItem] {
        items.sorted { ($0.subtitle ?? "") < ($1.subtitle ?? "") }
    }

    public var body: some View {
        if items.count <= 1 {
            singleItemBlock(focused)
        } else {
            multiItemBlock
        }
    }

    // MARK: Single item

    @ViewBuilder
    private func singleItemBlock(_ item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showListingBadges {
                listingBadges(item)
            }
            ProgressLine(item: item, hideDownloadClient: showListingBadges)
            ThinProgressBar(progress: item.progress, tint: item.status.tint)

            if showInlineUpgrade && item.isUpgrade {
                upgradeDiff(item)
                    .padding(.top, 4)
            }

            if showCustomFormats, !item.customFormats.isEmpty || item.customFormatScore != 0 {
                CustomFormatChips(formats: item.customFormats, score: item.customFormatScore)
            }

            if let release = item.releaseName, !release.isEmpty {
                Text(release)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    /// "Listing" badges that mirror the row-level title chips in QueueRowView:
    /// Upgrade/New capsule + download-client capsule. Used for Radarr's
    /// single-item card so the detail view echoes the listing's badges.
    @ViewBuilder
    private func listingBadges(_ item: QueueItem) -> some View {
        HStack(spacing: 4) {
            Text(item.isUpgrade ? "Upgrade" : "New")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(item.isUpgrade ? Color.indigo : Color.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    (item.isUpgrade ? Color.indigo : Color.accentColor).opacity(0.15),
                    in: Capsule()
                )

            if let client = item.downloadClient {
                let color = downloadClientColor(client)
                Text(client)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.15), in: Capsule())
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func upgradeDiff(_ item: QueueItem) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                DiffTag(text: "NEW", style: .new)
                qualityCells(
                    quality: item.quality,
                    size: item.sizeTotal,
                    score: item.customFormatScore,
                    tags: item.customFormats
                )
            }
            GridRow {
                DiffTag(text: "OLD", style: .old)
                qualityCells(
                    quality: item.existingQuality,
                    size: item.existingSize ?? 0,
                    score: item.existingCustomFormatScore ?? 0,
                    tags: item.existingCustomFormats
                )
            }
        }
    }

    @ViewBuilder
    private func qualityCells(quality: String?, size: Int64, score: Int, tags: [String]) -> some View {
        HStack(spacing: 4) {
            if let q = quality, !q.isEmpty {
                Text(q)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
            if size > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if score != 0 {
                Text("·").foregroundStyle(.tertiary)
                let sign = score > 0 ? "+" : ""
                Text("\(sign)\(score)")
                    .foregroundStyle(score > 0 ? Color.green : Color.red)
                    .font(.system(size: 11, weight: .semibold))
            }
            ForEach(tags, id: \.self) { TagChip(text: $0) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: Multi-item

    @ViewBuilder
    private var multiItemBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard listCollapsible else { return }
                withAnimation(.smooth(duration: 0.18)) { listExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if listCollapsible {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(listExpanded ? 90 : 0))
                    }
                    Text("In queue")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(items.count) downloads")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: aggregateSizeText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!listCollapsible)

            if !listCollapsible || listExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedItems) { it in
                        MultiRow(
                            item: it,
                            isFocused: it.id == focused.id,
                            showInlineUpgrade: showInlineUpgrade,
                            showCustomFormats: showCustomFormats,
                            hoverDetail: rowHoverDetail
                        )
                    }
                }
            }
        }
    }

    private var aggregateSizeText: String {
        let total = items.reduce(Int64(0)) { $0 + $1.sizeTotal }
        let left = items.reduce(Int64(0)) { $0 + $1.sizeLeft }
        let done = max(0, total - left)
        let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let doneStr = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
        return "\(doneStr) / \(totalStr)"
    }
}

private struct ProgressLine: View {
    let item: QueueItem
    var hideDownloadClient: Bool = false

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: item.status.symbol)
                .font(.system(size: 10))
                .foregroundStyle(item.status.tint)
            Text(LocalizedStringKey(item.status.displayName))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.status.tint)
            Text("·").foregroundStyle(.tertiary)
            Text(verbatim: "\(Int((item.progress * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            if let q = item.quality, !q.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(q)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let t = formattedTimeLeft {
                Text("·").foregroundStyle(.tertiary)
                Text(verbatim: t)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if item.sizeTotal > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text(verbatim: sizeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !hideDownloadClient, let client = item.downloadClient {
                Spacer(minLength: 6)
                Text(client)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(downloadClientColor(client))
            }
        }
    }

    private var sizeText: String {
        let done = max(0, item.sizeTotal - item.sizeLeft)
        return "\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file))"
    }

    private var formattedTimeLeft: String? {
        guard let raw = item.timeLeft, !raw.isEmpty else { return nil }
        let trimmed = String(raw.prefix { $0 != "." })
        return trimmed == "00:00:00" ? nil : trimmed
    }
}


private struct DiffTag: View {
    enum Style { case new, old }
    let text: String
    let style: Style

    public var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .tracking(0.5)
            .foregroundStyle(style == .new ? Color.accentColor : Color.secondary)
            .frame(width: 30, height: 14)
            .background(
                style == .new
                    ? Color.accentColor.opacity(0.18)
                    : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 3)
            )
    }
}

/// One row inside the multi-item list: status dot, episode/quality text,
/// and a thin progress bar. When `hoverDetail` is true and the item is an
/// upgrade, the row reveals existing-file detail on demand:
///   - macOS: hovering for ~350 ms opens a popover anchored to the row.
///   - iOS:   tapping the row toggles the same content inline below it.
private struct MultiRow: View {
    let item: QueueItem
    let isFocused: Bool
    var showInlineUpgrade: Bool = true
    var showCustomFormats: Bool = false
    var hoverDetail: Bool = false

    @State private var isHovering = false
    @State private var showHoverPopover = false
    @State private var hoverTask: Task<Void, Never>?
    /// iOS-only: tap-to-expand state for the inline existing-file block.
    @State private var showInlineExistingFile = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.status.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(item.status.tint)
                if let code = episodeCode {
                    Text(code)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text(headlineText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.isUpgrade {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.indigo)
                }
                Spacer(minLength: 4)
                Text(trailingText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            ThinProgressBar(progress: item.progress, tint: item.status.tint)
            if showCustomFormats, !item.customFormats.isEmpty || item.customFormatScore != 0 {
                CustomFormatChips(formats: item.customFormats, score: item.customFormatScore)
                    .padding(.top, 1)
            }
            if !hoverDetail, showInlineUpgrade, isFocused, item.isUpgrade {
                Text(verbatim: upgradeHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.indigo)
            }
            #if !os(macOS)
            // iOS: tap-to-expand existing-file block sits inline below
            // the row so we don't need a popover anchor.
            if hoverDetail, item.isUpgrade, showInlineExistingFile {
                ExistingFilePopover(item: item)
                    .padding(.top, 4)
            }
            #endif
        }
        .padding(.vertical, 3)
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowBackground)
        )
        .overlay(alignment: .leading) {
            if isFocused {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering in
            guard hoverDetail, item.isUpgrade else { return }
            isHovering = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if !Task.isCancelled, isHovering { showHoverPopover = true }
                }
            } else {
                showHoverPopover = false
            }
        }
        .popover(isPresented: $showHoverPopover, arrowEdge: .trailing) {
            ExistingFilePopover(item: item)
        }
        #else
        .onTapGesture {
            guard hoverDetail, item.isUpgrade else { return }
            withAnimation(.smooth(duration: 0.18)) { showInlineExistingFile.toggle() }
        }
        #endif
    }

    private var rowBackground: Color {
        if isFocused { return Color.accentColor.opacity(0.06) }
        if hoverDetail, isHovering, item.isUpgrade { return Color.primary.opacity(0.04) }
        return .clear
    }

    private var episodeCode: String? {
        guard let s = item.seasonNumber, let e = item.episodeNumber else { return nil }
        return String(format: "S%02dE%02d", s, e)
    }

    /// Episode title + quality, joined by a dot.
    private var headlineText: String {
        var bits: [String] = []
        if let t = item.episodeTitle, !t.isEmpty { bits.append(t) }
        if let q = item.quality, !q.isEmpty { bits.append(q) }
        if bits.isEmpty, let release = item.releaseName, !release.isEmpty { bits.append(release) }
        return bits.joined(separator: " · ")
    }

    private var trailingText: String {
        if item.status == .queued { return "Queued" }
        return "\(Int((item.progress * 100).rounded()))%"
    }

    private var upgradeHint: String {
        var bits: [String] = ["↑ replacing"]
        if let q = item.existingQuality, !q.isEmpty { bits.append(q) }
        if let s = item.existingCustomFormatScore, s != 0 {
            let sign = s > 0 ? "+" : ""
            bits.append("(\(sign)\(s))")
        }
        return bits.joined(separator: " ")
    }
}

/// Full-width existing-file banner for Radarr details. Sits between the
/// header card and the overview so the chips have room to breathe.
private struct ExistingFileBanner: View {
    let item: QueueItem
    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.doc.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.indigo)
                Text("Existing file")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if let q = item.existingQuality, !q.isEmpty {
                    Text(q)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
                if let size = item.existingSize, size > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let s = item.existingCustomFormatScore, s != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    let sign = s > 0 ? "+" : ""
                    Text("\(sign)\(s)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(s > 0 ? Color.green : Color.red)
                }
            }
            if !item.existingCustomFormats.isEmpty {
                TooltipFlowLayout(spacing: 4) {
                    ForEach(item.existingCustomFormats, id: \.self) { TagChip(text: $0) }
                }
            }
            if let name = item.existingFileName, !name.isEmpty {
                Text(name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.indigo.opacity(0.06))
        )
    }
}

/// Compact one-line summary of the existing file an item would replace.
/// Used in Radarr's header card under the rating chips.
private struct ExistingFileLine: View {
    let item: QueueItem

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.indigo)
                Text("Existing")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.indigo)
                if let q = item.existingQuality, !q.isEmpty {
                    Text(q)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let size = item.existingSize, size > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let s = item.existingCustomFormatScore, s != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    let sign = s > 0 ? "+" : ""
                    Text("\(sign)\(s)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(s > 0 ? Color.green : Color.red)
                }
            }
            if !item.existingCustomFormats.isEmpty {
                TooltipFlowLayout(spacing: 3) {
                    ForEach(item.existingCustomFormats, id: \.self) { TagChip(text: $0) }
                }
            }
        }
    }
}

/// Hover popover for ungrouped Sonarr rows that reveals the existing-file
/// details an upgrade would replace. Mirrors the chrome of `QueueItemTooltip`.
private struct ExistingFilePopover: View {
    let item: QueueItem

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.doc.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.indigo)
                Text("Will replace existing file")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.indigo)
            }

            if let sub = item.subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                if let q = item.existingQuality, !q.isEmpty {
                    Text(q).foregroundStyle(.primary)
                }
                if let size = item.existingSize, size > 0 {
                    if item.existingQuality?.isEmpty == false {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .foregroundStyle(.primary)
                }
                if let s = item.existingCustomFormatScore, s != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    let sign = s > 0 ? "+" : ""
                    Text("\(sign)\(s)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(s > 0 ? Color.green : Color.red)
                }
            }
            .font(.system(size: 11))

            if !item.existingCustomFormats.isEmpty {
                TooltipFlowLayout(spacing: 3) {
                    ForEach(item.existingCustomFormats, id: \.self) { TagChip(text: $0) }
                }
            }

            if let name = item.existingFileName, !name.isEmpty {
                Text(name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(width: 320)
        .background(.regularMaterial)
    }
}

private func formatDuration(ms: Int) -> String {
    let total = ms / 1000
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
