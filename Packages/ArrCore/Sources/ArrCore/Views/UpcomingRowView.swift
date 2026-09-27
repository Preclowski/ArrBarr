import SwiftUI
import MediaKit

/// Long-hover tooltip for any surface presenting an `UpcomingItem` (the
/// Upcoming tab's rows, the queue's "Next week" banner rows). Owns the
/// 600 ms dwell AND the three-state routing: a live download shows the
/// QUEUE tooltip for its row; otherwise the upcoming tooltip (library
/// style when downloaded, library-minus-file when not out yet).
struct UpcomingHoverTooltip: ViewModifier {
    let item: UpcomingItem
    @EnvironmentObject var configStore: ConfigStore

    func body(content: Content) -> some View {
        // Shared 600 ms hover plumbing (see `HoverTooltip`); this modifier
        // only owns the three-state ROUTING.
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
        configStore.serviceConfig(for: item.source).apiKey
    }

    /// The live queue row for THIS calendar entry, if one is downloading.
    /// Movies match on the arr record id; episodes need season+episode on
    /// top (the series id alone matches every episode of the show).
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
    /// See `UpcomingHoverTooltip`.
    func upcomingTooltip(item: UpcomingItem) -> some View {
        modifier(UpcomingHoverTooltip(item: item))
    }
}

public struct UpcomingRowView: View {
    let item: UpcomingItem
    @EnvironmentObject var configStore: ConfigStore

    public var body: some View {
        PosterMetadataRow(
            posterURL: item.posterURL,
            posterAPIKey: item.posterRequiresAuth ? apiKeyForSource : nil,
            posterSize: posterSize,
            posterBlurred: configStore.shouldBlurPoster(for: item.source),
            posterFallbackSymbol: item.source.symbol,
            // A calendar entry is always monitored — the arr wouldn't list it
            // otherwise — so only the watched wedge has anything to say here.
            // Asked per EPISODE for Sonarr rows: a show that is still airing is
            // never watched as a whole, so the title-level answer was always no.
            posterWatched: MediaServerIndex.shared.isWatched(item.mediaServerKeys,
                                                            season: item.seasonNumber,
                                                            episode: item.episodeNumber),
            title: item.title,
            metadataSegments: episodeSegments,
            metadataSegments2: ratingSegments,
            disabled: item.entityId == nil,
            onTap: openDetail,
            // Third line, at its start: the score leads the release-type /
            // runtime line it used to sit inside as text.
            metadataBadge2: {
                if let ratingChip { RatingPill(chip: ratingChip) }
            }
        ) {
            HStack(spacing: 6) {
                if item.hasFile {
                    // A calendar entry is always in the library, so the only
                    // news is "downloaded" — one ownership chip everywhere
                    // (see `LibraryStateBadge`).
                    LibraryStateBadge(isDownloaded: true)
                }
                // Which arr this upcoming item comes from.
                ServiceIcon(source: item.source, size: 13)
                    .foregroundStyle(.tertiary)
            }
        }
        .upcomingTooltip(item: item)
    }

    /// Row layout is three lines on every platform: title / episode / rating.
    /// Splitting episode info from the rating line stops a series row from
    /// cramming `S04E03 · Title · Airing · IMDb · runtime` onto one overflowing
    /// line. Movies (no episode subtitle) collapse to title + rating.
    ///
    /// Episode info (S00E00 · title) — its own line. For a Lidarr album there
    /// is no episode, so the line carries the track count instead: "12 tracks"
    /// is the one fact that distinguishes an upcoming single from an LP.
    private var episodeSegments: [String] {
        [
            item.subtitle.flatMap { $0.isEmpty ? nil : $0 },
            trackCountSegment,
        ].compactMap { $0 }
    }

    /// Pluralized in the view rather than in the client, so it follows the
    /// user's language. Same phrasing as the artist page's album rows.
    private var trackCountSegment: String? {
        guard let count = item.trackCount, count > 0 else { return nil }
        return String.localizedStringWithFormat(
            String(localized: "%lld tracks", bundle: .module), count)
    }

    /// Release type / runtime — the second line. The score moved off it into
    /// the chip beside it (`ratingChip`); airDate is deliberately omitted, as
    /// the list groups by day with the date as a section header.
    private var ratingSegments: [String] {
        [
            item.releaseTypeText(locale: configStore.currentLocale),
            item.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
        ].compactMap { $0 }
    }

    /// The row's score as the app's one rating chip — TVDB for series, IMDb
    /// with a TMDB fallback for movies (an unreleased title usually only has a
    /// TMDB score yet). Same source order the tooltip's pill uses; unlinked,
    /// like every other chip inside a list row.
    private var ratingChip: RatingChip? {
        if item.source == .sonarr {
            return item.imdb.flatMap { RatingChip.tvdb($0) }
        }
        if let chip = item.imdb.flatMap({ RatingChip.imdb($0) }) { return chip }
        return item.tmdb.flatMap { RatingChip.tmdb($0) }
    }

    private func openDetail() {
        guard let entityId = item.entityId else { return }
        // If this title is already downloading/importing, open the LIVE queue
        // item's detail — it carries the real status + the file being grabbed,
        // whereas a synthetic "upcoming" shell reads as unknown/new with no file.
        // A series' entityId maps to many episodes, so the series rows match on
        // the episode's own coordinates rather than on the series alone.
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
                // A calendar row IS an episode — open that, not its series.
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
        configStore.serviceConfig(for: item.source).apiKey
    }

}

// MARK: - Rich tooltip
//
// Mirrors `QueueItemTooltip`'s chrome (poster + header + info grid +
// overview) but pulls fields from `UpcomingItem` instead of a queue
// row. Surfaces what's actually useful before the episode/movie airs:
// air date/time, runtime, IMDb, release type, overview.

public struct UpcomingItemTooltip: View {
    let item: UpcomingItem
    var apiKey: String? = nil
    @EnvironmentObject var configStore: ConfigStore
    /// Normalized on-disk file facts, whichever arr they came from —
    /// `/moviefile` for movies, `/episodefile` (via the series map, keyed by
    /// the calendar's `episodeFileId`) for episodes.
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
    /// Assigned quality-profile name — lazily resolved like the file facts.
    @State private var profileName: String?
    /// Country of production — TMDB-only (see `CountryProvider`).
    @State private var countries: [String] = []
    @Environment(\.locale) private var locale

    public var body: some View {
        MediaTooltipChrome(
            title: item.title,
            subtitle: item.subtitle,
            posterURL: item.posterURL,
            posterRequiresAuth: item.posterRequiresAuth,
            apiKey: apiKey,
            posterSize: MediaTooltipChrome<EmptyView>.posterSize(for: item.source),
            blurred: configStore.shouldBlurPoster(for: item.source),
            fallbackSymbol: item.source.symbol,
            // Corner grammar mirrors the Library tooltip exactly:
            // [context: release status][status: ownership].
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
            // Library-tooltip order: genres → rating pills → runtime · cert →
            // table → overview → quality strip → filename.
            if !item.genres.isEmpty {
                GenreChips(genres: item.genres)
            }
            // Detail-hero order: metadata line above the rating pills.
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
            // Assigned profile — independent of the file (shown for
            // not-yet-released entries too, same as the Library tooltip).
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

    /// "119 min · R" — the same line the Library tooltip puts under the
    /// rating pills (runtime moved OUT of the info grid for parity).
    private var runtimeCertLine: String {
        var parts: [String] = []
        if let r = item.runtime, r > 0 { parts.append("\(r) min") }
        if let c = item.certification, !c.isEmpty { parts.append(c) }
        // Country closes the line, as it does in the detail hero.
        parts.append(contentsOf: CountryProvider.displayNames(countries, locale: locale))
        return parts.joined(separator: " · ")
    }

    /// Sonarr's calendar score is TVDB-sourced (it rides in `item.imdb` for
    /// historical reasons). Movies: IMDb, falling back to TMDB — unreleased
    /// titles usually have a TMDB score long before an IMDb one.
    /// Full pill set, same as the Library tooltip. Zero-hiding lives in the
    /// RatingChip factories.
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
            // Dotted key (not the bare literal "Type") — the string catalog
            // symbol generator rejects "Type" as too close to a Swift
            // reserved word.
            lines.append(TooltipInfoLine(labelKey: "upcoming.type.label", value: t))
        }
        // On-disk file facts (lazy-fetched) — the same rows the Library
        // tooltip carries, so an owned title reads identically in both.
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
