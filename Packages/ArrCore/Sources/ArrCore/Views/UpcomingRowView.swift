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
            metadataSegments: metadataSegments,
            disabled: item.entityId == nil,
            onTap: openDetail
        ) {
            if item.hasFile {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
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
        .popover(isPresented: $showTooltip, arrowEdge: .trailing) {
            UpcomingItemTooltip(item: item, apiKey: apiKeyForSource)
                .environmentObject(configStore)
                .popoverBehavior(.applicationDefined)
        }
        #endif
    }

    /// Dot-joined metadata mirroring `SearchResultRow`. Order: subtitle
    /// (S00E00 etc) → releaseType (Airing / Digital / In Cinemas) →
    /// IMDb → runtime. airDate is deliberately *not* here — the upcoming
    /// list groups by day with the date as a section header, so showing
    /// it again per row would just be noise.
    private var metadataSegments: [String] {
        [
            item.subtitle.flatMap { $0.isEmpty ? nil : $0 },
            item.releaseType.flatMap { $0.isEmpty ? nil : $0 },
            item.imdb.map { String(format: "IMDb %.1f", $0) },
            item.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
        ].compactMap { $0 }
    }

    private func openDetail() {
        guard let entityId = item.entityId else { return }
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
                    row("Type", value: t)
                }
                if let r = item.runtime, r > 0 {
                    row("Runtime", value: "\(r) min")
                }
                if let v = item.imdb {
                    row("IMDb", value: String(format: "%.1f", v))
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
