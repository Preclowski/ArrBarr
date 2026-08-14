import SwiftUI

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
                    apiKey: active.posterRequiresAuth ? apiKey : nil,
                    locale: configStore.currentLocale
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
            title: item.title,
            metadataSegments: episodeSegments,
            metadataSegments2: ratingSegments,
            disabled: item.entityId == nil,
            onTap: openDetail
        ) {
            HStack(spacing: 6) {
                if item.hasFile {
                    // Same accent-tinted pill as the search view's library
                    // hits — one visual for "you already own this" across
                    // every surface (see `InLibraryBadge`).
                    InLibraryBadge()
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
    /// Episode info (S00E00 · title) — its own line.
    private var episodeSegments: [String] {
        [item.subtitle.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }
    }

    /// Release type / IMDb / runtime — the rating line below the episode line.
    /// airDate is deliberately omitted: the list groups by day with the date as
    /// a section header, so repeating it per row would just be noise.
    private var ratingSegments: [String] {
        [
            item.releaseTypeText(locale: configStore.currentLocale),
            ratingSegment,
            item.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
        ].compactMap { $0 }
    }

    /// Rating text for the row — TVDB for series; movies IMDb with a TMDB
    /// fallback (unreleased titles usually only have a TMDB score yet).
    /// Same source/fallback order the tooltip's rating pill uses.
    private var ratingSegment: String? {
        // Zero = not rated yet — hidden, same rule as the pill factories.
        if item.source == .sonarr {
            return item.imdb.flatMap { $0 > 0 ? String(format: "TVDB %.1f", $0) : nil }
        }
        if let v = item.imdb, v > 0 { return String(format: "IMDb %.1f", v) }
        if let v = item.tmdb, v > 0 { return String(format: "TMDB %.1f", v) }
        return nil
    }

    private func openDetail() {
        guard let entityId = item.entityId else { return }
        // If this title is already downloading/importing, open the LIVE queue
        // item's detail — it carries the real status + the file being grabbed,
        // whereas a synthetic "upcoming" shell reads as unknown/new with no file.
        // Movies only: a series' entityId (seriesId) maps to many episodes, so we
        // can't pick the right queue row here.
        if item.source == .radarr || item.source == .whisparr,
           let active = QueueViewModel.shared.items(for: item.source)
            .first(where: { $0.entityId == entityId }) {
            DetailRequest.post(active)
            return
        }
        DetailRequest.post(
            DetailRequest.syntheticItem(
                source: item.source,
                entityId: entityId,
                title: item.title,
                posterURL: item.posterURL,
                posterRequiresAuth: item.posterRequiresAuth
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

        // Episodes carry ONLY what the episode surfaces (detail banner)
        // show: quality, size, formats, file name. No group/languages —
        // the tooltip must stay a subset of the library/detail views for
        // the same entity type, never a superset.
        init(_ f: SonarrEpisodeFile) {
            quality = f.quality?.name
            size = f.size
            releaseGroup = nil
            languages = []
            formats = (f.customFormats ?? []).map(\.name)
            score = f.customFormatScore ?? 0
            fileName = f.relativePath
        }
    }

    @State private var fileDetails: FileFacts?
    /// Assigned quality-profile name — lazily resolved like the file facts.
    @State private var profileName: String?

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
            TooltipRatingPills(chips: ratingChips)
            if !runtimeCertLine.isEmpty {
                Text(verbatim: runtimeCertLine)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
            // Assigned profile — independent of the file (shown for
            // not-yet-released entries too, same as the Library tooltip).
            if profileName == nil, let profileId = item.qualityProfileId {
                let config = configStore.config(for: item.source.serviceKind)
                profileName = await SearchClient.profileNameMap(config: config, source: item.source)[profileId]
            }
            guard item.hasFile, fileDetails == nil, let entityId = item.entityId else { return }
            switch item.source {
            case .radarr:
                if let f = try? await RadarrClient(config: configStore.radarr).fetchMovieFile(movieId: entityId) {
                    fileDetails = FileFacts(f)
                }
            case .whisparr:
                if let f = try? await WhisparrClient(config: configStore.whisparr).fetchMovieFile(movieId: entityId) {
                    fileDetails = FileFacts(f)
                }
            case .sonarr:
                // entityId is the SERIES id; the calendar's episodeFileId
                // picks this episode's file out of the series map.
                guard let fileId = item.episodeFileId else { break }
                let map = (try? await SonarrClient(config: configStore.sonarr).fetchEpisodeFileMap(seriesId: entityId)) ?? [:]
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
