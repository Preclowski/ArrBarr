import SwiftUI
import AppKit

/// A single Sonarr row that represents a *season pack* — one physical
/// download whose Sonarr-side queue surfaces as N expected-episode entries
/// sharing the same `downloadId`. The data model still calls this a "group"
/// (because internally it gathers N items into one), but visually it reads
/// as a normal queue row with a season tag and an episode count badge —
/// no expansion, no chevron. The whole download is one unit, period.
struct QueueGroupRowView: View {
    let group: QueueGroup
    /// Acts on the whole download. Applied to the representative item; all
    /// members share its downloadId so the arr's queue API affects the
    /// entire pack.
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

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

    var body: some View {
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
                        Text("Season pack")
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
                .hoverActions(visible: isHovering) { actionButtons }

                ProgressView(value: rep.progress)
                    .progressViewStyle(.linear)
                    .tint(rep.status.tint)
                    .frame(height: 3)

                if !rep.customFormats.isEmpty {
                    customFormatTags
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

    // MARK: - Custom format tags
    //
    // All members of the group share the same physical release, so they
    // share the same custom-format tags and score — render the rep's.

    private var customFormatTags: some View {
        Color.clear
            .frame(height: 14)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                HStack(spacing: 4) {
                    ForEach(rep.customFormats, id: \.self) { cf in
                        Text(cf)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    if rep.customFormatScore != 0 {
                        let sign = rep.customFormatScore > 0 ? "+" : ""
                        Text("\(sign)\(rep.customFormatScore)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(rep.customFormatScore > 0 ? .green : .red)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                .fixedSize()
            }
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}

// MARK: - Season pack tooltip

/// Hover popover for season-pack rows. Mirrors QueueItemTooltip's chrome
/// (poster + info grid + tags) but the header swaps the per-episode
/// subtitle for season + episode-count metadata, and a list of expected
/// episodes is appended at the bottom so the user can see which episodes
/// the pack covers without expanding the row.
struct QueueGroupTooltip: View {
    let group: QueueGroup
    var apiKey: String? = nil
    var locale: Locale = Locale(identifier: "en")

    private var rep: QueueItem { group.representative }

    private func loc(_ key: String) -> String { LocaleBundle.string(key, locale: locale) }

    var body: some View {
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
                episodeList
            }

            if rep.isUpgrade {
                upgradeDivider
                Text(verbatim: loc("Existing files"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                existingInfo
            }
        }
    }

    /// Same Apple-y upgrade divider QueueItemTooltip uses, restated here so
    /// the season tooltip has visual continuity with the per-episode one.
    private var upgradeDivider: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            Text(verbatim: loc("Upgrade"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.indigo)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.indigo.opacity(0.15), in: Capsule())
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
        }
        .padding(.top, 4)
    }

    /// Per-episode block of what each new file is *replacing*. Each episode
    /// gets three lines:
    ///   1. Episode label · old quality
    ///   2. Old custom-format tags (gradient-fading on the right when they
    ///      overflow) followed by the old score chip
    ///   3. Old filename (monospaced, middle-truncated)
    ///
    /// Episodes with no existing-file metadata are omitted (those are fresh
    /// additions inside an otherwise-upgrade pack — nothing to replace).
    @ViewBuilder
    private var existingInfo: some View {
        if upgradedMembers.isEmpty {
            Text(verbatim: loc("Replacing existing files"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(upgradedMembers) { member in
                    existingMemberBlock(member)
                }
            }
        }
    }

    private func existingMemberBlock(_ member: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Single header line: episode label · old quality · tags
            // (gradient-faded on overflow) · score chip on the far right.
            HStack(alignment: .center, spacing: 6) {
                Text(episodeTag(for: member))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                if let q = member.existingQuality, !q.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(q)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                existingTagsRow(for: member)
                if let s = member.existingCustomFormatScore, s != 0 {
                    let sign = s > 0 ? "+" : ""
                    Text("\(sign)\(s)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(s > 0 ? .green : .red)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }

            if let name = member.existingFileName, !name.isEmpty {
                Text(name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Existing-file tag chips, fading out at the right when the row would
    /// otherwise overflow. Empty if the member has no existing tags.
    /// Tag chips for a member's existing file, taking the remaining flex
    /// width inside the header line. Fades out on the right via a gradient
    /// mask when the chips overflow. When the member has no existing tags
    /// the row collapses into a flexible Spacer so the score chip still
    /// pins to the right.
    @ViewBuilder
    private func existingTagsRow(for member: QueueItem) -> some View {
        if member.existingCustomFormats.isEmpty {
            Spacer(minLength: 0)
        } else {
            Color.clear
                .frame(height: 16)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    HStack(spacing: 4) {
                        ForEach(member.existingCustomFormats, id: \.self) { cf in
                            Text(cf)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                    .fixedSize()
                }
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.85),
                            .init(color: .clear, location: 1.0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }

    private var upgradedMembers: [QueueItem] {
        group.items.filter {
            $0.existingFileName != nil
                || $0.existingQuality != nil
                || ($0.existingCustomFormatScore ?? 0) != 0
                || !$0.existingCustomFormats.isEmpty
        }
    }

    /// "S01E03" extracted from the member's subtitle, falling back to the
    /// raw subtitle if the regex misses.
    private func episodeTag(for item: QueueItem) -> String {
        guard let s = item.subtitle else { return "—" }
        let pattern = "S\\d+E\\d+"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let range = Range(match.range, in: s) {
            return String(s[range]).uppercased()
        }
        return s
    }

    @ViewBuilder
    private func scoreText(for score: Int?) -> some View {
        if let s = score, s != 0 {
            let sign = s > 0 ? "+" : ""
            Text("\(sign)\(s)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(s > 0 ? .green : .red)
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
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

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(group.items) { item in
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
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

