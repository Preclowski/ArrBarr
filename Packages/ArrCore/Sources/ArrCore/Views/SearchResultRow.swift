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
    /// Drives the row's trailing affordance: a chevron + "In library"
    /// pill (tap drills into DetailView) instead of the addable `+`
    /// (tap opens SearchAddPanel).
    private var isInLibrary: Bool { result.inLibraryArrId != nil }

    public var body: some View {
        PosterMetadataRow(
            posterURL: result.posterURL,
            posterAPIKey: nil,
            posterSize: CGSize(width: 26, height: 38),
            posterBlurred: configStore.shouldBlurPoster(for: result.source),
            title: titleWithYear,
            metadataSegments: metadataSegments,
            // Title slot: arr identity ("Sonarr"/"Radarr") and, if
            // the title is already in the library, a quiet "library"
            // tag. Add-new candidates get no badge — absence of the
            // library tag is the signal (the `+` affordance on the
            // trailing edge confirms intent). Avoids burning a chip
            // on what is effectively the default state.
            titleBadge: AnyView(HStack(spacing: 4) {
                SourceGlyphChip(source: result.source)
                if isInLibrary {
                    InLibraryBadge()
                }
            }),
            onTap: onTap
        ) {
            if isInLibrary {
                // Apple-standard "drill in" affordance — same chevron
                // the system uses in Settings, Music, App Store.
                Image(systemName: "chevron.right")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "plus")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
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
                if hasRatingsRow {
                    HStack(spacing: 6) {
                        if let v = result.imdb { ratingChip(label: "IMDb", value: String(format: "%.1f", v), color: .yellow) }
                        if let v = result.rottenTomatoes { ratingChip(label: "RT", value: "\(Int(v))%", color: .red) }
                        if let v = result.metacritic { ratingChip(label: "MC", value: "\(Int(v))", color: .green) }
                        if result.imdb == nil, let v = result.rating {
                            ratingChip(label: "★", value: String(format: "%.1f", v), color: .yellow)
                        }
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

    private var hasRatingsRow: Bool {
        result.imdb != nil || result.rottenTomatoes != nil
            || result.metacritic != nil || result.rating != nil
    }

    @ViewBuilder
    private func ratingChip(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(color)
            Text(value)
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }
}
