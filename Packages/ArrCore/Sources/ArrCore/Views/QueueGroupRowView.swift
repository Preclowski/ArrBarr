import SwiftUI

/// A single Sonarr row that represents a *season pack* — one physical
/// download whose Sonarr-side queue surfaces as N expected-episode entries
/// sharing the same `downloadId`. The data model still calls this a "group"
/// (because internally it gathers N items into one), but visually it reads
/// as a normal queue row with a season tag and an episode count badge —
/// no expansion, no chevron. The whole download is one unit, period.
public struct QueueGroupRowView: View {
    let group: QueueGroup
    /// Acts on the whole download. Applied to the representative item; all
    /// members share its downloadId so the arr's queue API affects the
    /// entire pack.
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    var onShowDetail: (() -> Void)? = nil

    @EnvironmentObject var configStore: ConfigStore
    @State private var isHovering = false
    @State private var showDeleteConfirmation = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    private var rep: QueueItem { group.representative }

    private var canControl: Bool {
        switch rep.downloadProtocol {
        case .usenet:
            return (configStore.sabnzbd.isConfigured && !configStore.sabnzbd.apiKey.isEmpty)
                || configStore.nzbget.isConfigured
        case .torrent:
            return configStore.qbittorrent.isConfigured
                || configStore.transmission.isConfigured
                || configStore.rtorrent.isConfigured
                || configStore.deluge.isConfigured
        case .unknown:
            return false
        }
    }

    private var canPauseResume: Bool {
        rep.status == .downloading || rep.status == .paused
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemotePoster(
                url: rep.posterURL,
                apiKey: rep.posterRequiresAuth ? configStore.sonarr.apiKey : nil,
                size: CGSize(width: 40, height: 60),
                cornerRadius: 4,
                fallbackSymbol: "tv"
            )

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(rep.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // Title-row badges: colour-tinted capsules, mirrors
                        // QueueRowView so the row reads as a sibling.
                        // `.virtual` bundles say just "Season" — they're N
                        // independent downloads, not one physical pack, and
                        // the user shouldn't be misled into thinking the
                        // release is a single torrent/nzb.
                        Text(group.kind == .pack ? "Season pack" : "Season")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.teal)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.teal.opacity(0.15), in: Capsule())

                        Text(rep.isUpgrade ? "Upgrade" : "New")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(rep.isUpgrade ? AnyShapeStyle(Color.indigo) : AnyShapeStyle(Color.accentColor))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                rep.isUpgrade ? AnyShapeStyle(Color.indigo.opacity(0.15)) : AnyShapeStyle(Color.accentColor.opacity(0.15)),
                                in: Capsule()
                            )

                        if let client = rep.downloadClient {
                            let color = downloadClientColor(client)
                            Text(client)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(color)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(color.opacity(0.15), in: Capsule())
                                .lineLimit(1)
                        }
                    }

                    if let label = seasonLabel {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 3) {
                        Image(systemName: rep.status.symbol)
                            .foregroundStyle(rep.status.tint)
                            .font(.system(size: 8))
                        Text(LocalizedStringKey(rep.status.displayName))
                            .foregroundStyle(rep.status.tint)
                        if let q = rep.quality, !q.isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                            Text(q).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 10))
                    .lineLimit(1)
                }
                // See QueueRowView: tooltip popover steals the mouse, so we
                // also treat `showTooltip` as "still hovering" to keep the
                // pause/remove icons reachable while the tooltip is up.
                .hoverActions(visible: isHovering || showTooltip) { actionButtons }

                ThinProgressBar(progress: aggregateProgress, tint: rep.status.tint)

                if !rep.customFormats.isEmpty || rep.customFormatScore != 0 {
                    CustomFormatStrip(
                        formats: rep.customFormats,
                        score: rep.customFormatScore
                    )
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onShowDetail?()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
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
            QueueGroupTooltip(
                group: group,
                apiKey: rep.posterRequiresAuth ? configStore.sonarr.apiKey : nil,
                locale: configStore.currentLocale
            )
        }
        .alert("Remove download?", isPresented: $showDeleteConfirmation) {
            Button("Remove", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(headerLabel)\" (\(group.memberCount) episodes) from the download client.")
        }
    }

    // MARK: - Header text

    /// Second line under the series title.
    /// - Single-season pack → "Season 01 · 5 episodes"
    /// - Mixed-season pack  → "Multiple seasons · 12 episodes"
    /// - No parsable season → nil (the second line is hidden)
    private var seasonLabel: String? {
        let seasons = Set(group.items.compactMap { Self.parseSeason(from: $0.subtitle) })
        if seasons.count == 1, let s = seasons.first {
            let seasonText = String(format: String(localized: "Season %02lld"), s)
            return "\(seasonText) · \(episodeCountText)"
        }
        if seasons.count > 1 {
            return "\(String(localized: "Multiple seasons")) · \(episodeCountText)"
        }
        return nil
    }

    /// Used in the alert; same logic as `seasonLabel` but always returns
    /// something readable.
    private var headerLabel: String {
        if let s = seasonLabel { return "\(rep.title) — \(s)" }
        return rep.title
    }

    private var episodeCountText: String {
        String(format: String(localized: "%lld episodes"), group.memberCount)
    }

    /// Aggregate completion across all members. For `.pack` groups this
    /// reduces to the rep's progress (every member is the same physical
    /// download with the same size/sizeleft). For `.virtual` bundles each
    /// member is its own download, so weighted-by-size aggregation is the
    /// only honest summary — a 60% bar means the bundle as a whole is 60%
    /// transferred. Falls back to a count-based mean if no sizes are known.
    private var aggregateProgress: Double {
        let total = group.items.reduce(Int64(0)) { $0 + $1.sizeTotal }
        let left  = group.items.reduce(Int64(0)) { $0 + $1.sizeLeft }
        if total > 0 {
            return max(0, min(1, 1.0 - Double(left) / Double(total)))
        }
        let count = Double(group.items.count)
        guard count > 0 else { return 0 }
        return group.items.reduce(0.0) { $0 + $1.progress } / count
    }

    private static func parseSeason(from subtitle: String?) -> Int? {
        guard let s = subtitle else { return nil }
        let pattern = "S(\\d+)E\\d+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range(at: 1), in: s)
        else { return nil }
        return Int(s[range])
    }

    // MARK: - Actions

    private var actionButtons: some View {
        // Spacing 6 (not 4) because macOS 26's `.glass` button style
        // auto-merges adjacent buttons into a single "joined glass" capsule
        // when they're closer together — that's what was making them look
        // glued in some rows. A wider gap keeps them distinct.
        HStack(spacing: 6) {
            if canControl && canPauseResume {
                if rep.isPaused {
                    IconButton(symbol: "play.fill", helpKey: "Resume", accessibilityLabel: "Resume \(headerLabel)") {
                        onResume()
                    }
                } else {
                    IconButton(symbol: "pause.fill", helpKey: "Pause", accessibilityLabel: "Pause \(headerLabel)") {
                        onPause()
                    }
                }
            }
            if canControl {
                IconButton(symbol: "trash", helpKey: "Remove from client", accessibilityLabel: "Remove \(headerLabel)") {
                    showDeleteConfirmation = true
                }
            }
        }
    }

}

// MARK: - Season pack tooltip

/// Hover popover for season-pack rows. Mirrors QueueItemTooltip's chrome
/// (poster + info grid + tags) but the header swaps the per-episode
/// subtitle for season + episode-count metadata, and a list of expected
/// episodes is appended at the bottom so the user can see which episodes
/// the pack covers without expanding the row.
public struct QueueGroupTooltip: View {
    let group: QueueGroup
    var apiKey: String? = nil
    var locale: Locale = Locale(identifier: "en")

    private var rep: QueueItem { group.representative }

    private func loc(_ key: String) -> String { LocaleBundle.string(key, locale: locale) }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemotePoster(
                url: rep.posterURL,
                apiKey: apiKey,
                size: CGSize(width: 110, height: 165),
                cornerRadius: 6,
                fallbackSymbol: "tv"
            )
            tooltipContent
        }
        .padding(12)
        .frame(width: 480)
        .background(.regularMaterial)
    }

    private var tooltipContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider().opacity(0.5)
            infoGrid

            if !rep.customFormats.isEmpty || rep.customFormatScore != 0 {
                tagsSection(
                    score: rep.customFormatScore != 0 ? rep.customFormatScore : nil,
                    tags: rep.customFormats
                )
            }

            if !group.items.isEmpty {
                Text(verbatim: loc("Episodes"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.top, 4)
                episodeQueueList
            }
        }
    }

    /// Replaces the legacy episode list + heavy "existing files" block with
    /// the same compact queue-row presentation used in `DetailView`. Each
    /// episode shows a status dot, episode code, headline, percent, thin
    /// progress bar, and any custom-format chips. Upgrades surface an
    /// indigo arrow icon — full existing-file detail still lives in the
    /// detail view (this is just a hover preview).
    private var episodeQueueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(group.items) { it in
                TooltipQueueRow(item: it)
            }
        }
    }


    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 6) {
                Text(rep.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let client = rep.downloadClient {
                    let color = downloadClientColor(client)
                    Text(client)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.15), in: Capsule())
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: 4) {
                if let label = seasonLabel {
                    Text(label)
                    Text("·").foregroundStyle(.tertiary)
                }
                Text(String(format: loc("%lld episodes"), group.memberCount))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var infoGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            if let q = rep.quality, !q.isEmpty {
                row("Quality", value: "\(q) · \(sizeString)")
            } else {
                row("Size", value: sizeString)
            }
            if let indexer = rep.indexer, !indexer.isEmpty {
                row("Indexer", value: indexer)
            }
            if let file = rep.releaseName, !file.isEmpty {
                row("File", value: file, mono: true, wraps: true)
            }
        }
    }

    @ViewBuilder
    private func tagsSection(score: Int?, tags: [String]) -> some View {
        if !tags.isEmpty || score != nil {
            TooltipFlowLayout(spacing: 3) {
                ForEach(tags, id: \.self) { TagChip(text: $0) }
                if let score, score != 0 {
                    let sign = score > 0 ? "+" : ""
                    TagChip(text: "\(sign)\(score)", color: score > 0 ? .green : .red)
                }
            }
            .padding(.top, 2)
        }
    }

    private var seasonLabel: String? {
        let seasons = Set(group.items.compactMap { Self.parseSeason(from: $0.subtitle) })
        if seasons.count == 1, let s = seasons.first {
            return String(format: loc("Season %02lld"), s)
        }
        if seasons.count > 1 {
            return loc("Multiple seasons")
        }
        return nil
    }

    private static func parseSeason(from subtitle: String?) -> Int? {
        guard let s = subtitle else { return nil }
        let pattern = "S(\\d+)E\\d+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range(at: 1), in: s)
        else { return nil }
        return Int(s[range])
    }

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: rep.sizeTotal, countStyle: .file)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, mono: Bool = false, wraps: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(verbatim: loc(label))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .lineLimit(wraps ? nil : 2)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Compact queue row used inside the season-pack tooltip. Mirrors the
/// detail-view multi-row look: status icon, episode code, headline,
/// percent, thin progress bar, custom-format chips, and an indigo arrow
/// when the episode is replacing an existing file.
public struct TooltipQueueRow: View {
    let item: QueueItem

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.status.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(item.status.tint)
                if let code = episodeCode {
                    Text(code)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text(headline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.isUpgrade {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.indigo)
                }
                Spacer(minLength: 4)
                Text(trailing)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.10))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(item.status.tint)
                        .frame(width: geo.size.width * max(0, min(1, item.progress)))
                }
            }
            .frame(height: 3)
            if !item.customFormats.isEmpty || item.customFormatScore != 0 {
                TooltipFlowLayout(spacing: 3) {
                    ForEach(item.customFormats, id: \.self) { TagChip(text: $0) }
                    if item.customFormatScore != 0 {
                        let sign = item.customFormatScore > 0 ? "+" : ""
                        TagChip(
                            text: "\(sign)\(item.customFormatScore)",
                            color: item.customFormatScore > 0 ? .green : .red
                        )
                    }
                }
                .padding(.top, 1)
            }
        }
    }

    private var episodeCode: String? {
        guard let s = item.subtitle else { return nil }
        let pattern = "S\\d+E\\d+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range, in: s)
        else { return nil }
        return String(s[range]).uppercased()
    }

    private var headline: String {
        var bits: [String] = []
        if let s = item.subtitle, let code = episodeCode {
            let stripped = s.replacingOccurrences(of: code, with: "", options: .caseInsensitive)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ·–—-"))
            if !stripped.isEmpty { bits.append(stripped) }
        }
        if let q = item.quality, !q.isEmpty { bits.append(q) }
        return bits.joined(separator: " · ")
    }

    private var trailing: String {
        if item.status == .queued { return "Queued" }
        return "\(Int((item.progress * 100).rounded()))%"
    }
}

