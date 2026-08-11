import SwiftUI

public struct UpcomingRowView: View {
    let item: UpcomingItem
    @EnvironmentObject var configStore: ConfigStore
    @State private var isHovering = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

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
        #if os(macOS)
        // Long-hover rich tooltip — same 600 ms gate + .leading
        // anchor as the queue rows', so the muscle memory carries
        // across surfaces.
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task { @MainActor [self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if !Task.isCancelled && self.isHovering { showTooltip = true }
                }
            } else {
                showTooltip = false
            }
        }
        .tooltipPopover(isPresented: $showTooltip, arrowEdge: .trailing) {
            UpcomingItemTooltip(item: item, apiKey: apiKeyForSource)
                .environmentObject(configStore)
        }
        #endif
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
            item.releaseType.flatMap { $0.isEmpty ? nil : $0 },
            item.imdb.map { String(format: "IMDb %.1f", $0) },
            item.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
        ].compactMap { $0 }
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

    public var body: some View {
        MediaTooltipChrome(
            title: item.title,
            subtitle: item.subtitle,
            posterURL: item.posterURL,
            posterRequiresAuth: item.posterRequiresAuth,
            apiKey: apiKey,
            posterSize: posterSize,
            blurred: configStore.shouldBlurPoster(for: item.source),
            fallbackSymbol: item.source.symbol,
            overview: item.overview
        ) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                row("Airs", value: item.airDateFormatted(locale: configStore.currentLocale))
                if let t = item.releaseType, !t.isEmpty {
                    // Dotted key (not the bare literal "Type") — the string
                    // catalog symbol generator rejects "Type" as too close to a
                    // Swift reserved word.
                    row("upcoming.type.label", value: t)
                }
                if let r = item.runtime, r > 0 {
                    row("Runtime", value: "\(r) min")
                }
                if let v = item.imdb {
                    // Brand mark in the label column — same icon-for-text swap
                    // as the rating pills everywhere else.
                    GridRow(alignment: .firstTextBaseline) {
                        Image("rating-imdb", bundle: .module)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 11)
                            .gridColumnAlignment(.leading)
                            .accessibilityLabel(Text(verbatim: "IMDb"))
                        Text(String(format: "%.1f", v))
                            .scaledFont(size: 11)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var posterSize: CGSize {
        switch item.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 90, height: 135)
        case .lidarr: return CGSize(width: 90, height: 90)
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label), bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .scaledFont(size: 11)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
