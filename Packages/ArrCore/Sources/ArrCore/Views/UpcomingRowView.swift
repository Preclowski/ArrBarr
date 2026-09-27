import SwiftUI
import MediaKit

/// Long-hover tooltip for an `UpcomingItem`: a live download shows its queue
/// tooltip, anything else the upcoming tooltip.
struct UpcomingHoverTooltip: ViewModifier {
    let item: UpcomingItem
    @EnvironmentObject var configStore: ConfigStore

    func body(content: Content) -> some View {
        content.hoverTooltip {
            if let active = activeQueueItem {
                QueueItemTooltip(
                    item: active,
                    apiKey: active.posterRequiresAuth ? apiKey : nil
                )
                .environmentObject(configStore)
            } else {
                UpcomingItemTooltip(item: item, apiKey: apiKey)
                    .environmentObject(configStore)
            }
        }
    }

    private var apiKey: String? {
        configStore.config(for: item.source).apiKey
    }

    /// Episodes match on season+episode too: the series id alone matches every episode.
    private var activeQueueItem: QueueItem? {
        guard let entityId = item.entityId else { return nil }
        let pool = QueueViewModel.shared.items(for: item.source)
        switch item.source {
        case .sonarr:
            guard let sn = item.seasonNumber, let en = item.episodeNumber else { return nil }
            return pool.first { $0.entityId == entityId && $0.seasonNumber == sn && $0.episodeNumber == en }
        case .radarr, .whisparr, .lidarr:
            return pool.first { $0.entityId == entityId }
        }
    }
}

extension View {
    func upcomingTooltip(item: UpcomingItem) -> some View {
        modifier(UpcomingHoverTooltip(item: item))
    }
}

struct UpcomingRowView: View {
    let item: UpcomingItem
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        PosterMetadataRow(
            posterURL: item.posterURL,
            posterAPIKey: item.posterRequiresAuth ? apiKeyForSource : nil,
            posterSize: posterSize,
            posterBlurred: configStore.shouldBlurPoster(for: item.source),
            posterFallbackSymbol: item.source.symbol,
            // A calendar entry is always monitored. Watched is asked per episode:
            // a still-airing show is never watched as a whole.
            posterWatched: MediaServerIndex.shared.isWatched(item.mediaServerKeys,
                                                            season: item.seasonNumber,
                                                            episode: item.episodeNumber),
            title: item.title,
            metadataSegments: episodeSegments,
            metadataSegments2: ratingSegments,
            disabled: item.entityId == nil,
            onTap: openDetail,
            metadataBadge2: {
                if let ratingChip { RatingPill(chip: ratingChip) }
            }
        ) {
            HStack(spacing: 6) {
                if item.hasFile {
                    // A calendar entry is always in the library, so only "downloaded" is news.
                    LibraryStateBadge(isDownloaded: true)
                }
                ServiceIcon(source: item.source, size: 13)
                    .foregroundStyle(.tertiary)
            }
        }
        .upcomingTooltip(item: item)
    }

    /// A Lidarr album has no episode, so the line carries the track count: the
    /// one fact that tells a single from an LP.
    private var episodeSegments: [String] {
        [
            item.subtitle.flatMap { $0.isEmpty ? nil : $0 },
            trackCountSegment,
        ].compactMap { $0 }
    }

    /// Pluralized in the view rather than in the client, so it follows the
    /// user's language.
    private var trackCountSegment: String? {
        guard let count = item.trackCount, count > 0 else { return nil }
        return String.localizedStringWithFormat(
            String(localized: "%lld tracks", bundle: .module), count)
    }

    /// No air date: the list groups by day with the date as a section header.
    private var ratingSegments: [String] {
        [
            item.releaseTypeText(locale: configStore.currentLocale),
            item.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
        ].compactMap { $0 }
    }

    /// TVDB for series, IMDb then TMDB for movies (an unreleased title usually
    /// only has a TMDB score yet).
    private var ratingChip: RatingChip? {
        if item.source == .sonarr {
            return item.imdb.flatMap { RatingChip.tvdb($0) }
        }
        if let chip = item.imdb.flatMap({ RatingChip.imdb($0) }) { return chip }
        return item.tmdb.flatMap { RatingChip.tmdb($0) }
    }

    private func openDetail() {
        guard let entityId = item.entityId else { return }
        // Open the live queue item if one is downloading: a synthetic shell reads
        // as new with no file. Series match on the episode's own coordinates.
        let live = QueueViewModel.shared.items(for: item.source).first { queued in
            guard queued.entityId == entityId else { return false }
            guard item.source == .sonarr else { return true }
            return queued.seasonNumber == item.seasonNumber
                && queued.episodeNumber == item.episodeNumber
        }
        if let live {
            DetailRequest.post(live)
            return
        }
        DetailRequest.post(
            DetailRequest.syntheticItem(
                source: item.source,
                entityId: entityId,
                title: item.title,
                posterURL: item.posterURL,
                posterRequiresAuth: item.posterRequiresAuth,
                seasonNumber: item.seasonNumber,
                episodeNumber: item.episodeNumber
            )
        )
    }

    private var posterSize: CGSize {
        switch item.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 26, height: 38)
        case .lidarr: return CGSize(width: 26, height: 26)
        }
    }

    private var apiKeyForSource: String? {
        configStore.config(for: item.source).apiKey
    }

}

// MARK: - Rich tooltip

struct UpcomingItemTooltip: View {
    let item: UpcomingItem
    var apiKey: String? = nil
    @EnvironmentObject var configStore: ConfigStore
    /// `/moviefile` for movies, `/episodefile` (series map keyed by the calendar's
    /// `episodeFileId`) for episodes.
    struct FileFacts {
        let quality: String?
        let size: Int64?
        let releaseGroup: String?
        let languages: [String]
        let formats: [String]
        let score: Int
        let fileName: String?

        init(_ f: ArrFile) {
            quality = f.quality?.name
            size = f.size
            releaseGroup = f.releaseGroup
            languages = (f.languages ?? []).compactMap(\.name)
            formats = (f.customFormats ?? []).map(\.name)
            score = f.customFormatScore ?? 0
            fileName = f.relativePath
        }
    }

    @State private var fileDetails: FileFacts?
    @State private var profileName: String?
    @State private var countries: [String] = []
    @Environment(\.locale) private var locale

    var body: some View {
        MediaTooltipChrome(
            title: item.title,
            subtitle: item.subtitle,
            posterURL: item.posterURL,
            posterRequiresAuth: item.posterRequiresAuth,
            apiKey: apiKey,
            posterSize: MediaTooltipChrome<EmptyView>.posterSize(for: item.source),
            blurred: configStore.shouldBlurPoster(for: item.source),
            fallbackSymbol: item.source.symbol,
            contextChip: ArrReleaseStatusLabel.text(item.releaseStatus, locale: configStore.currentLocale)
                .map { AnyView(TagChip(text: $0)) },
            statusChip: AnyView(StateChip(
                text: AppLocalized.string(
                    item.hasFile ? "Downloaded"
                        : (item.airDate > Date() ? "library.status.notAvailable" : "search.missing.button"),
                    locale: configStore.currentLocale),
                color: item.hasFile ? .green : (item.airDate > Date() ? .blue : .red)
            ))
        ) {
            if !item.genres.isEmpty {
                GenreChips(genres: item.genres)
            }
            if !runtimeCertLine.isEmpty {
                Text(verbatim: runtimeCertLine)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TooltipRatingPills(chips: ratingChips)
            TooltipInfoGrid(lines: infoLines)
            TooltipOverview(text: item.overview)
            if profileName != nil || fileDetails.map({ !$0.formats.isEmpty || $0.score != 0 }) == true {
                TooltipFlowLayout(spacing: 3) {
                    if let profileName {
                        ProfileChip(name: profileName)
                    }
                    ForEach(fileDetails?.formats ?? [], id: \.self) { TagChip(text: $0) }
                    if let score = fileDetails?.score, score != 0 {
                        ScoreChip(score: score)
                    }
                }
                .padding(.top, 2)
            }
            TooltipFileName(name: fileDetails?.fileName)
        }
        .task {
            switch item.source {
            case .radarr:
                countries = await CountryProvider.movieCountries(
                    tmdbId: item.tmdbId, configStore: configStore)
            case .sonarr:
                countries = await CountryProvider.seriesCountries(
                    tmdbId: nil, tvdbId: item.tvdbId, configStore: configStore)
            case .lidarr, .whisparr:
                break
            }
        }
        .task {
            if profileName == nil, let profileId = item.qualityProfileId {
                let config = configStore.config(for: item.source.serviceKind)
                profileName = await SearchClient.profileNameMap(config: config, source: item.source)[profileId]
            }
            guard item.hasFile, fileDetails == nil, let entityId = item.entityId else { return }
            switch item.source {
            case .radarr:
                if let f = try? await configStore.radarrClient.fetchMovieFile(movieId: entityId) {
                    fileDetails = FileFacts(f)
                }
            case .whisparr:
                if let f = try? await configStore.whisparrClient.fetchMovieFile(movieId: entityId) {
                    fileDetails = FileFacts(f)
                }
            case .sonarr:
                // entityId is the SERIES id; the calendar's episodeFileId
                // picks this episode's file out of the series map.
                guard let fileId = item.episodeFileId else { break }
                let map = (try? await configStore.sonarrClient.fetchEpisodeFileMap(seriesId: entityId)) ?? [:]
                if let f = map[fileId] {
                    fileDetails = FileFacts(f)
                }
            case .lidarr:
                break
            }
        }
    }

    private var runtimeCertLine: String {
        var parts: [String] = []
        if let r = item.runtime, r > 0 { parts.append("\(r) min") }
        if let c = item.certification, !c.isEmpty { parts.append(c) }
        parts.append(contentsOf: CountryProvider.displayNames(countries, locale: locale))
        return parts.joined(separator: " · ")
    }

    /// Sonarr's calendar score is TVDB-sourced though it rides in `item.imdb`.
    private var ratingChips: [RatingChip] {
        if item.source == .sonarr {
            return [item.imdb.flatMap { RatingChip.tvdb($0) }].compactMap { $0 }
        }
        return [
            item.imdb.flatMap { RatingChip.imdb($0) },
            item.tmdb.flatMap { RatingChip.tmdb($0) },
            item.ratingRt.flatMap { RatingChip.rottenTomatoes($0) },
            item.ratingMetacritic.flatMap { RatingChip.metacritic($0) },
        ].compactMap { $0 }
    }

    private var infoLines: [TooltipInfoLine] {
        var lines: [TooltipInfoLine] = [
            TooltipInfoLine(labelKey: "Airs", value: item.airDateTimeFormatted(locale: configStore.currentLocale)),
        ]
        if let t = item.releaseTypeText(locale: configStore.currentLocale) {
            // Dotted key: the string-catalog symbol generator rejects "Type" as a reserved word.
            lines.append(TooltipInfoLine(labelKey: "upcoming.type.label", value: t))
        }
        if let file = fileDetails {
            if let q = file.quality, !q.isEmpty {
                lines.append(TooltipInfoLine(labelKey: "Quality", value: q))
            }
            if let s = file.size, s > 0 {
                lines.append(TooltipInfoLine(labelKey: "Size", value: ByteCountFormatter.string(fromByteCount: s, countStyle: .file)))
            }
            if let g = file.releaseGroup, !g.isEmpty {
                lines.append(TooltipInfoLine(labelKey: "Release group", value: g))
            }
            if !file.languages.isEmpty {
                lines.append(TooltipInfoLine(labelKey: "Languages", value: file.languages.joined(separator: ", ")))
            }
        }
        return lines
    }
}
