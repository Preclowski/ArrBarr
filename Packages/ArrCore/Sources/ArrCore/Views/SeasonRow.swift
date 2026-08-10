import SwiftUI

/// One season's summary row in the series detail — the whole row is a progress
/// bar (status-tinted fill spanning have/total). Tapping it pushes the full
/// `SeasonDetailView` (episodes + that season's search buttons).
struct SeasonRow: View {
    let season: SonarrSeasonInfo
    /// This season's episodes — only used to detect an in-progress download for
    /// the status tint/icon (the episode list itself lives in SeasonDetailView).
    let episodes: [SonarrEpisodeDetail]
    var queueByEpisodeId: [Int: [QueueItem]] = [:]
    var onTap: () -> Void = {}

    private var stats: SonarrSeasonStats? { season.statistics }
    private var have: Int { stats?.episodeFileCount ?? 0 }
    private var total: Int { stats?.totalEpisodeCount ?? stats?.episodeCount ?? 0 }
    private var pct: Double { total > 0 ? min(1.0, Double(have) / Double(total)) : 0 }
    private var anyDownloading: Bool {
        episodes.contains { ep in
            guard let items = queueByEpisodeId[ep.id] else { return false }
            return items.contains { $0.status == .downloading || $0.status == .queued || $0.status == .importing }
        }
    }
    private var isComplete: Bool { total > 0 && have >= total }
    /// Sonarr's own flag for THIS season — never derived from its episodes.
    /// arr has no tri-state here either, so neither do we. `nil` (older
    /// Sonarr / a fork that omits the field) reads as monitored so we don't
    /// dim every row on a server that simply doesn't report it.
    private var isMonitored: Bool { season.monitored ?? true }
    /// Blue while anything's downloading, green when complete, neutral otherwise
    /// (a partial/idle season isn't an error).
    private var fillTint: Color {
        if anyDownloading { return .accentColor }
        if isComplete { return .green }
        return .primary
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Leading state column, same place arr puts it. The trailing
                // edge is already spoken for (have/total + chevron), and a
                // fixed width keeps every "Season NN" aligned down the list
                // regardless of which glyph the row is showing.
                MonitorBookmark(isMonitored: isMonitored, size: 10)
                    .frame(width: 11, alignment: .leading)
                Text(String(format: "Season %02d", season.seasonNumber))
                    .scaledFont(size: 12, weight: .medium)
                Spacer(minLength: 8)
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
            // Dim label AND progress fill together — arr dims unmonitored
            // seasons too, and the wash reads from across the popover in a
            // way a 10pt outline glyph never could.
            .opacity(isMonitored ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .accessibilityValue(
            isMonitored ? Text(verbatim: "")
                        : Text("common.notMonitored.label", bundle: .module)
        )
        .buttonStyle(.plain)
        .linkRowHover()
    }
}
