import SwiftUI

/// One season's summary row in the series detail — the whole row is a progress
/// bar (status-tinted fill spanning have/total). Tapping it pushes the full
/// `SeasonDetailView` (episodes + that season's search buttons).
struct SeasonRow: View {
    let season: SonarrSeasonInfo
    /// Every queue item belonging to THIS season — taken straight off the
    /// series' queue siblings by season number. It used to be derived by
    /// joining an episode-id map against the loaded episode array, which meant
    /// a season pack left no trace on the row whenever that join missed
    /// (episodes not loaded yet, or a pack member without an episode number).
    var queueItems: [QueueItem] = []
    var onTap: () -> Void = {}

    private var stats: SonarrSeasonStats? { season.statistics }
    private var have: Int { stats?.episodeFileCount ?? 0 }
    private var total: Int { stats?.totalEpisodeCount ?? stats?.episodeCount ?? 0 }
    private var pct: Double { total > 0 ? min(1.0, Double(have) / Double(total)) : 0 }
    private var anyDownloading: Bool { !queueItems.isEmpty }
    /// A season whose incoming download replaces files already on disk. The
    /// row otherwise looked identical to a fresh grab — same blue fill, same
    /// "10/10" — with nothing saying the season is being upgraded, while the
    /// episode rows inside it carry exactly this badge.
    private var isUpgrade: Bool { queueItems.contains(where: \.isUpgrade) }
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
                // Same Upgrade / New vocabulary the episode rows use, and the
                // same place: trailing edge, ahead of the row's number.
                if anyDownloading {
                    MediaBadgeCluster(isUpgrade: isUpgrade, size: .subtle)
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
