import SwiftUI

struct SearchResultRow: View {
    let result: SearchResult
    let onTap: () -> Void

    @EnvironmentObject var configStore: ConfigStore
    @Environment(\.locale) private var locale

    /// Arr lookups carry no country, so it comes from TMDB via `CountryProvider`, whose cache the detail view reuses.
    @State private var countries: [String] = []

    /// Guards against empty popover chrome on results stripped of overview/genres by an upstream cache.
    private var hasTooltipContent: Bool {
        (result.overview.map { !$0.isEmpty } ?? false) || !result.genres.isEmpty || !countries.isEmpty
    }

    /// Set by `SearchViewModel.fetchOne`; tap drills into DetailView when true, SearchAddPanel otherwise.
    private var isInLibrary: Bool { result.inLibraryArrId != nil }

    var body: some View {
        PosterMetadataRow(
            posterURL: result.posterURL,
            // Library rows point at the arr's MediaCover route, which needs the key; TMDB/TVDB must never see it.
            posterAPIKey: result.posterRequiresAuth
                ? configStore.config(for: result.source.serviceKind).apiKey : nil,
            posterSize: CGSize(width: 26, height: 38),
            posterBlurred: configStore.shouldBlurPoster(for: result.source),
            posterFallbackSymbol: result.source.symbol,
            // A lookup hit carries no arr record, so there is no monitored flag to draw.
            posterWatched: MediaServerIndex.shared.isWatched(result.mediaServerKeys),
            title: titleWithYear,
            metadataSegments: metadataSegments,
            onTap: onTap,
            titleBadge: { SourceGlyphChip(source: result.source) }
        ) {
            // No second trailing chevron or `+`: the title chevron is the drill-in, like every other row surface.
            if isInLibrary {
                LibraryStateBadge(isDownloaded: result.libraryDownloaded)
            }
        }
        #if os(macOS)
        // No extra request: uses what the lookup already sent.
        .hoverTooltip(enabled: hasTooltipContent) {
            SearchResultTooltip(result: result, countries: countries)
                .environmentObject(configStore)
        }
        #endif
        .task(id: result.id) { countries = await loadCountries() }
    }

    /// Sonarr rows carry TMDB's series id when SkyHook shipped one, else the TVDB id. Whisparr ids aren't TMDB ids.
    private func loadCountries() async -> [String] {
        switch result.source {
        case .radarr:
            return await CountryProvider.movieCountries(
                tmdbId: result.externalId, configStore: configStore)
        case .sonarr:
            return await CountryProvider.seriesCountries(
                tmdbId: result.tmdbTVId, tvdbId: result.externalId,
                configStore: configStore)
        case .lidarr, .whisparr:
            return []
        }
    }

    private var titleWithYear: String {
        if let year = result.year {
            return "\(result.title) (\(year))"
        }
        return result.title
    }

    /// All from the lookup response, so zero extra requests. One country only: a co-production's full list
    /// belongs to the tooltip and the detail.
    private var metadataSegments: [String] {
        let country: String? = CountryProvider.displayNames(countries, locale: locale, limit: 1).first
        let segments: [String?] = [
            result.subtitle.flatMap { $0.isEmpty ? nil : $0 },
            result.imdb.flatMap { $0 > 0 ? "IMDb \($0.ratingText)" : nil },
            result.rottenTomatoes.flatMap { $0 > 0 ? "RT \(Int($0))%" : nil },
            result.metacritic.flatMap { $0 > 0 ? "MC \(Int($0))" : nil },
            result.imdb == nil ? result.rating.flatMap { $0 > 0 ? "★\($0.ratingText)" : nil } : nil,
            result.runtime.flatMap { $0 > 0 ? $0.runtimeText : nil },
            result.certification.flatMap { $0.isEmpty ? nil : $0 },
            country,
        ]
        return segments.compactMap { $0 }
    }
}

// MARK: - Rich tooltip

struct SearchResultTooltip: View {
    let result: SearchResult
    var countries: [String] = []
    @EnvironmentObject var configStore: ConfigStore
    @Environment(\.locale) private var locale

    var body: some View {
        MediaTooltipChrome(
            title: result.title,
            year: result.year,
            subtitle: result.subtitle,
            posterURL: result.posterURL,
            posterSize: MediaTooltipChrome<EmptyView>.posterSize(for: result.source),
            blurred: configStore.shouldBlurPoster(for: result.source),
            fallbackSymbol: result.source.symbol
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if !result.genres.isEmpty {
                    GenreChips(genres: result.genres)
                }
                if !runtimeCertLine.isEmpty {
                    Text(verbatim: runtimeCertLine)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                TooltipRatingPills(chips: ratingChips)
                TooltipInfoGrid(lines: infoLines)
                TooltipOverview(text: result.overview)
            }
        }
    }

    /// `network` holds Sonarr's network or Radarr's studio.
    private var infoLines: [TooltipInfoLine] {
        var lines: [TooltipInfoLine] = []
        if let n = result.network, !n.isEmpty {
            lines.append(TooltipInfoLine(
                labelKey: result.source == .sonarr ? "search.network.label" : "search.studio.label",
                value: n
            ))
        }
        return lines
    }

    private var runtimeCertLine: String {
        var parts: [String] = []
        if let r = result.runtime, r > 0 { parts.append(r.runtimeText) }
        if let c = result.certification, !c.isEmpty { parts.append(c) }
        parts.append(contentsOf: CountryProvider.displayNames(countries, locale: locale))
        return parts.joined(separator: " · ")
    }

    /// No links — a tooltip is hover chrome. The bare-rating fallback is TVDB for Sonarr, TMDB otherwise.
    private var ratingChips: [RatingChip] {
        var chips: [RatingChip] = [
            result.imdb.flatMap { RatingChip.imdb($0) },
            result.rottenTomatoes.flatMap { RatingChip.rottenTomatoes($0) },
            result.metacritic.flatMap { RatingChip.metacritic($0) },
        ].compactMap { $0 }
        if result.imdb == nil, let v = result.rating,
           let chip = result.source == .sonarr ? RatingChip.tvdb(v) : RatingChip.tmdb(v) {
            chips.append(chip)
        }
        return chips
    }
}
