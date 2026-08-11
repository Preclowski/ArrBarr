import SwiftUI

public struct SearchResultRow: View {
    let result: SearchResult
    let onTap: () -> Void

    @EnvironmentObject var configStore: ConfigStore
    @State private var isHovering = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

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
        // additional network call. Same 600 ms gate as queue rows so
        // the muscle memory carries.
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            if hovering, hasTooltipContent {
                hoverTask = Task { @MainActor [self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if !Task.isCancelled && self.isHovering { showTooltip = true }
                }
            } else {
                showTooltip = false
            }
        }
        .tooltipPopover(isPresented: $showTooltip, arrowEdge: .trailing) {
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
            result.imdb.map { String(format: "IMDb %.1f", $0) },
            result.rottenTomatoes.map { "RT \(Int($0))%" },
            result.metacritic.map { "MC \(Int($0))" },
            result.imdb == nil ? result.rating.map { String(format: "★%.1f", $0) } : nil,
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
            posterSize: posterSize,
            blurred: configStore.shouldBlurPoster(for: result.source),
            fallbackSymbol: result.source.symbol,
            overview: result.overview
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if !result.genres.isEmpty {
                    TooltipFlowLayout(spacing: 3) {
                        ForEach(result.genres, id: \.self) { TagChip(text: $0) }
                    }
                }
                if !ratingChips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(ratingChips, id: \.label) { RatingPill(chip: $0) }
                    }
                }
                if let n = result.network, !n.isEmpty {
                    Text(n)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var posterSize: CGSize {
        switch result.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 90, height: 135)
        case .lidarr: return CGSize(width: 90, height: 90)
        }
    }

    /// Same brand-icon pills as the detail headers (`RatingPill`), minus the
    /// links — a tooltip is hover chrome, not a click target. The bare-rating
    /// fallback is TVDB-sourced for Sonarr results and TMDB otherwise.
    private var ratingChips: [RatingChip] {
        var chips: [RatingChip] = []
        if let v = result.imdb {
            chips.append(RatingChip(label: "IMDb", value: String(format: "%.1f", v),
                                    color: .yellow, iconName: "rating-imdb"))
        }
        if let v = result.rottenTomatoes {
            chips.append(RatingChip(label: "RT", value: "\(Int(v))%",
                                    color: .red, iconName: "rating-rt"))
        }
        if let v = result.metacritic {
            chips.append(RatingChip(label: "MC", value: "\(Int(v))", color: .green))
        }
        if result.imdb == nil, let v = result.rating {
            chips.append(result.source == .sonarr
                ? RatingChip(label: "TVDB", value: String(format: "%.1f", v),
                             color: .blue, iconName: "rating-tvdb")
                : RatingChip(label: "TMDB", value: String(format: "%.1f", v),
                             color: .teal, iconName: "rating-tmdb"))
        }
        return chips
    }
}
