import SwiftUI

public struct SearchResultRow: View {
    let result: SearchResult
    let onTap: () -> Void

    @EnvironmentObject var configStore: ConfigStore

    /// True when the search result carries enough metadata to populate
    /// a tooltip — guards against renderering empty popover chrome on
    /// results stripped of overview/genres by an upstream cache.
    private var hasTooltipContent: Bool {
        (result.overview.map { !$0.isEmpty } ?? false) || !result.genres.isEmpty
    }

    /// True when this result is already in the user's arr library.
    /// Set by `SearchViewModel.fetchOne` from the library-id map.
    /// Drives the row's trailing "In library" pill (tap drills into
    /// DetailView; without it, tap opens SearchAddPanel).
    private var isInLibrary: Bool { result.inLibraryArrId != nil }

    public var body: some View {
        PosterMetadataRow(
            posterURL: result.posterURL,
            posterAPIKey: nil,
            posterSize: CGSize(width: 26, height: 38),
            posterBlurred: configStore.shouldBlurPoster(for: result.source),
            posterFallbackSymbol: result.source.symbol,
            title: titleWithYear,
            metadataSegments: metadataSegments,
            // Title slot: arr identity ("Sonarr"/"Radarr") only. The
            // library tag lives on the trailing edge with the other
            // ownership affordances — same placement as the queue /
            // upcoming rows, so every surface reads the same way.
            titleBadge: AnyView(SourceGlyphChip(source: result.source)),
            onTap: onTap
        ) {
            // Trailing edge carries only the ownership badge. The drill-in
            // affordance is the title chevron PosterMetadataRow already
            // draws — a second trailing chevron (or a `+`) made search rows
            // read differently from every other row surface.
            if isInLibrary {
                InLibraryBadge()
            }
        }
        #if os(macOS)
        // Long-hover rich tooltip — reuses the overview / genres /
        // ratings that arr's lookup already sent with this result, no
        // additional network call. Shared 600 ms plumbing (HoverTooltip).
        .hoverTooltip(enabled: hasTooltipContent) {
            SearchResultTooltip(result: result)
                .environmentObject(configStore)
        }
        #endif
    }

    /// "Title (1994)" — same idea as MediaHeaderCard. The year is just a
    /// year, so it joins the title rather than burning a metadata segment.
    private var titleWithYear: String {
        if let year = result.year {
            return "\(result.title) (\(year))"
        }
        return result.title
    }

    /// Second-line metadata. Arr's lookup endpoint hands us all of these in
    /// the same response that fetched the row, so showing them costs zero
    /// extra requests: subtitle (Sonarr "X seasons" / Lidarr disambiguation)
    /// → IMDb → RT → Metacritic → ★ (TMDB, when IMDb is missing) → runtime
    /// → certification. Filter to what's populated.
    private var metadataSegments: [String] {
        [
            result.subtitle.flatMap { $0.isEmpty ? nil : $0 },
            result.imdb.flatMap { $0 > 0 ? String(format: "IMDb %.1f", $0) : nil },
            result.rottenTomatoes.flatMap { $0 > 0 ? "RT \(Int($0))%" : nil },
            result.metacritic.flatMap { $0 > 0 ? "MC \(Int($0))" : nil },
            result.imdb == nil ? result.rating.flatMap { $0 > 0 ? String(format: "★%.1f", $0) : nil } : nil,
            result.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
            result.certification.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }
}

// MARK: - Rich tooltip
//
// Hover preview for a search row. Pulls solely from data the
// `*_lookup` endpoint already sent — no extra network round-trip.
// Mirrors the queue / upcoming tooltip chrome (poster + heading +
// info grid + overview) so the user reads one tooltip vocabulary
// across the app.

public struct SearchResultTooltip: View {
    let result: SearchResult
    @EnvironmentObject var configStore: ConfigStore

    public var body: some View {
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
                // Same order as detail heroes / the library tooltip:
                // genres (GenreChips), rating pills, then extras.
                if !result.genres.isEmpty {
                    GenreChips(genres: result.genres)
                }
                TooltipRatingPills(chips: ratingChips)
                TooltipInfoGrid(lines: infoLines)
                TooltipOverview(text: result.overview)
            }
        }
    }

    /// Labeled facts — the same table form every other tooltip carries.
    /// `network` holds Sonarr's network or Radarr's studio; label follows.
    private var infoLines: [TooltipInfoLine] {
        var lines: [TooltipInfoLine] = []
        if let n = result.network, !n.isEmpty {
            lines.append(TooltipInfoLine(
                labelKey: result.source == .sonarr ? "search.network.label" : "search.studio.label",
                value: n
            ))
        }
        if let r = result.runtime, r > 0 {
            lines.append(TooltipInfoLine(labelKey: "Runtime", value: "\(r) min"))
        }
        return lines
    }

    /// Same brand-icon pills as the detail headers (`RatingPill`), minus the
    /// links — a tooltip is hover chrome, not a click target. The bare-rating
    /// fallback is TVDB-sourced for Sonarr results and TMDB otherwise.
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
