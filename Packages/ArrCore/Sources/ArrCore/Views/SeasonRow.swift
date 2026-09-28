import SwiftUI
import MediaKit

struct SeasonRow: View {
    let season: ArrSeason
    /// Taken by season number, not joined through episode ids: that join drops packs.
    var queueItems: [QueueItem] = []
    var onTap: () -> Void = {}
    /// `nil` keeps the bookmark an inert glyph.
    var onSetMonitored: ((Bool) async -> Void)? = nil
    /// Both nil leaves the row without a menu.
    var onAutomaticSearch: (() async throws -> Void)? = nil
    var onManualSearch: (() -> Void)? = nil

    @State private var searchFeedback: SearchFeedback = .idle

    private var stats: ArrStatistics? { season.statistics }
    private var have: Int { stats?.episodeFileCount ?? 0 }
    private var total: Int { stats?.totalEpisodeCount ?? stats?.episodeCount ?? 0 }
    private var pct: Double { total > 0 ? min(1.0, Double(have) / Double(total)) : 0 }
    private var anyDownloading: Bool { !queueItems.isEmpty }
    private var isUpgrade: Bool { queueItems.contains(where: \.isUpgrade) }
    private var isComplete: Bool { total > 0 && have >= total }
    /// Sonarr's own season flag. `nil` (older Sonarr / forks) reads as monitored.
    private var isMonitored: Bool { season.monitored ?? true }
    /// A partial or idle season isn't an error, so neutral.
    private var fillTint: Color {
        if anyDownloading { return .accentColor }
        if isComplete { return .green }
        return .primary
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Reserves the bookmark column (the bookmark is an overlay) so names align.
                Color.clear
                    .frame(width: 11, height: 12)
                Text(String(format: "Season %02d", season.seasonNumber))
                    .scaledFont(size: 12, weight: .medium)
                Spacer(minLength: 8)
                // The context menu closes on click, so the row shows the sweep itself.
                SearchFeedbackIcon(feedback: searchFeedback)
                if anyDownloading {
                    MediaBadgeCluster(isUpgrade: isUpgrade)
                }
                Text(verbatim: "\(have)/\(total)")
                    .scaledFont(size: 10, monospacedDigit: true)
                    .foregroundStyle(isComplete ? Color.green : Color.secondary)
                LinkChevron(size: 9)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                GeometryReader { geo in
                    Rectangle()
                        .fill(fillTint.opacity(anyDownloading ? 0.20 : isComplete ? 0.16 : 0.08))
                        .frame(width: geo.size.width * max(pct, total == 0 ? 0 : 0.015))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip))
            .opacity(isMonitored ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        // Outside the row Button: a nested Button doesn't reliably win the tap.
        .overlay(alignment: .leading) {
            MonitorRowToggle(isMonitored: isMonitored, entity: .season, onToggle: onSetMonitored)
                .padding(.leading, 10)
        }
        .accessibilityValue(
            isMonitored ? Text(verbatim: "")
                        : Text("common.notMonitored.label", bundle: .module)
        )
        .buttonStyle(.plain)
        .modifier(OptionalRowSearchMenu(
            feedback: $searchFeedback,
            onAutomatic: onAutomaticSearch, onManual: onManualSearch))
        .linkRowHover()
    }
}
