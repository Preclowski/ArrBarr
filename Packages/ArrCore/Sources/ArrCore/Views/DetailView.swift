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
        let pool = viewModel.items(for: item.source)
        guard let id = item.entityId else { return [item] }
        let matched = pool.filter { $0.entityId == id }
        return matched.isEmpty ? [item] : matched
    }

    /// True when at least one sibling is a real queue row (non-zero arrQueueId).
    /// `false` means this view was opened from a synthetic lookup item (chat
    /// card / upcoming row tap) and there's nothing to download right now —
    /// rendering a 0%/Unknown progress bar would be misleading.
    private var hasActiveDownloads: Bool {
        siblings.contains { $0.arrQueueId != 0 }
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

            if let url = arrWebURL(for: item, in: configStore) {
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
            case .radarr, .whisparr: movieContent
            case .sonarr:            sonarrContent
            case .lidarr:            lidarrContent
            }
        }
    }

    // MARK: - Movie (Radarr + Whisparr share the same layout since Whisparr
    //          is a Radarr fork operating on the same RadarrMovieDetail type)

    @ViewBuilder
    private var movieContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerCard(
                title: radarrDetail?.title ?? item.title,
                year: radarrDetail?.year,
                runtime: radarrDetail?.runtime,
                genres: radarrDetail?.genres ?? [],
                certification: radarrDetail?.certification,
                ratings: movieRatingChips,
                existingTrailer: nil,
                posterUrl: arrPosterURL(images: radarrDetail?.images, for: item, in: configStore),
                fallbackSymbol: "film",
                posterAspect: 2.0/3.0
            )

            if item.isUpgrade {
                ExistingFileBanner(item: item)
            }

            if let overview = radarrDetail?.overview, !overview.isEmpty {
                ExpandableOverview(text: overview)
            }

            if hasActiveDownloads {
                DownloadSection(
                    items: siblings,
                    focused: item,
                    showInlineUpgrade: false,
                    showCustomFormats: true,
                    showListingBadges: true
                )
            }

            if let err = loadError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var movieRatingChips: [RatingChip] {
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
                posterUrl: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore),
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

            if hasActiveDownloads {
                DownloadSection(
                    items: siblings,
                    focused: item,
                    showInlineUpgrade: true,
                    showCustomFormats: true,
                    rowHoverDetail: true,
                    listCollapsible: true,
                    listExpandedDefault: false
                )
            }

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

            if hasActiveDownloads {
                DownloadSection(items: siblings, focused: item)
            }

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
        let posterUrl = arrPosterURL(images: album?.images, for: item, in: configStore)
            ?? arrPosterURL(images: album?.artist?.images, for: item, in: configStore)
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
            apiKey: arrAPIKey(for: item, in: configStore),
            fallbackSymbol: fallbackSymbol,
            posterAspect: posterAspect,
            blurred: configStore.shouldBlurPoster(for: item.source),
            trailing: existingTrailer.map { AnyView(ExistingFileLine(item: $0)) }
        )
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
            case .whisparr:
                let client = WhisparrClient(config: configStore.whisparr)
                radarrDetail = try await client.fetchMovieDetails(id: entityId)
            }
        } catch {
            loadError = "Couldn't load details: \(error.localizedDescription)"
        }
    }
}
