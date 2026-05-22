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
    /// True when the host already has a permanent detail pane (desktop
    /// window). Suppresses the long-hover tooltip popover.
    @Environment(\.suppressRowTooltip) private var suppressRowTooltip
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
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: rep.source), cornerRadius: 4) {
                RemotePoster(
                    url: rep.posterURL,
                    apiKey: rep.posterRequiresAuth ? configStore.sonarr.apiKey : nil,
                    size: CGSize(width: 40, height: 60),
                    cornerRadius: 4,
                    fallbackSymbol: "tv"
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(rep.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // Title-row badges: Upgrade/New + download client,
                        // matching QueueRowView (and Radarr's movie row)
                        // exactly. The pack-shape callout used to live
                        // here as a third teal pill — it's been demoted
                        // into the subtitle line below where it belongs
                        // alongside other shape descriptors.
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
                // iOS has no hover so the icons stay always-visible.
                #if os(macOS)
                .hoverActions(visible: isHovering || showTooltip) { actionButtons }
                #else
                .hoverActions(visible: true) { actionButtons }
                #endif

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
        // macOS-only hover affordances: row tint + 600 ms delayed tooltip.
        // iOS users tap the row to drill into the detail view, which
        // surfaces the same content as the macOS tooltip.
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            // Skip the long-hover tooltip when the host has a detail pane.
            hoverTask?.cancel()
            if hovering && !suppressRowTooltip {
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
        #endif
        .alert("Remove download?", isPresented: $showDeleteConfirmation) {
            Button("Remove", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(headerLabel)\" (\(group.memberCount) episodes) from the download client.")
        }
    }

    // MARK: - Header text

    /// Second line under the series title. Unified subtitle shape:
    ///   - Single-season pack → "Season 01 · season pack · 5 episodes"
    ///   - Mixed-season pack  → "Multiple seasons · season pack · 12 episodes"
    ///   - No parsable season → "Season pack · 5 episodes" as a fallback.
    ///
    /// "Season pack" used to be a third coloured pill in the title row; it
    /// describes the *shape* of the download, not its *state*, so it
    /// belongs in the subtitle alongside other shape descriptors.
    private var seasonLabel: String? {
        let seasons = Set(group.items.compactMap(\.seasonNumber))
        let packLabel = String(localized: "season pack")
        if seasons.count == 1, let s = seasons.first {
            let seasonText = String(format: String(localized: "Season %02lld"), s)
            return "\(seasonText) · \(packLabel) · \(episodeCountText)"
        }
        if seasons.count > 1 {
            return "\(String(localized: "Multiple seasons")) · \(packLabel) · \(episodeCountText)"
        }
        return "\(String(localized: "Season pack")) · \(episodeCountText)"
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
        // See QueueRowView.actionButtons — dismiss the transient popover
        // eagerly when the cursor enters the buttons so the first click
        // hits the button instead of being eaten by popover dismissal.
        #if os(macOS)
        .onHover { hovering in
            if hovering {
                hoverTask?.cancel()
                showTooltip = false
            }
        }
        #endif
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
    @EnvironmentObject var configStore: ConfigStore

    private var rep: QueueItem { group.representative }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: rep.source), cornerRadius: 6) {
                RemotePoster(
                    url: rep.posterURL,
                    apiKey: apiKey,
                    size: CGSize(width: 110, height: 165),
                    cornerRadius: 6,
                    fallbackSymbol: "tv"
                )
            }
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
                customFormatChipStrip(
                    tags: rep.customFormats,
                    score: rep.customFormatScore != 0 ? rep.customFormatScore : nil
                )
            }

            // Variant A — every upgrade episode is replacing the same kind
            // of file. Render the summary card once between the header and
            // the episode list; per-episode rows then collapse to just
            // status/code/title/progress.
            if let uniform = uniformExistingFile {
                replacesSummary(uniform: uniform)
            }

            if !group.items.isEmpty {
                Text("Episodes", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.top, 4)
                episodeQueueList
            }
        }
    }

    /// Snapshot of an episode's existing-file metadata used to detect
    /// "all five episodes are upgrading from the same release" so we can
    /// hoist a single summary card instead of repeating identical chip
    /// rows under each episode.
    private struct ExistingFingerprint: Equatable {
        let quality: String
        let score: Int
        let formats: [String]
    }

    private func existingFingerprint(_ item: QueueItem) -> ExistingFingerprint? {
        // Only count rows that actually carry existing-file metadata —
        // a fresh add inside an otherwise-upgrade pack should not
        // collapse the summary, but it also shouldn't poison "all the
        // upgrades match" detection.
        guard item.isUpgrade,
              let q = item.existingQuality, !q.isEmpty
        else { return nil }
        return ExistingFingerprint(
            quality: q,
            score: item.existingCustomFormatScore ?? 0,
            formats: item.existingCustomFormats.sorted()
        )
    }

    /// Returns the shared existing-file fingerprint when *every* upgrade
    /// row in the pack carries identical existing metadata. Returns nil
    /// the moment two rows differ — the per-episode "replaces …" path
    /// then handles the heterogeneous case.
    private var uniformExistingFile: ExistingFingerprint? {
        let prints = group.items.compactMap(existingFingerprint)
        guard !prints.isEmpty else { return nil }
        // Need at least two upgrade rows to bother with a summary; one
        // upgrade row inside an otherwise-fresh pack reads cleaner with
        // its own per-row replaces line.
        guard prints.count >= 2 else { return nil }
        let first = prints[0]
        guard prints.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    @ViewBuilder
    private func replacesSummary(uniform: ExistingFingerprint) -> some View {
        let upgradeCount = group.items.filter(\.isUpgrade).count
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.doc.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.indigo)
                Text("Replacing all \(upgradeCount) episodes", bundle: .module)
                    .font(.system(size: 9, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.indigo)
            }
            HStack(spacing: 4) {
                Text(uniform.quality).foregroundStyle(.primary)
                if uniform.score != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    let sign = uniform.score > 0 ? "+" : ""
                    Text("\(sign)\(uniform.score)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(uniform.score > 0 ? Color.green : Color.red)
                }
                ForEach(uniform.formats, id: \.self) { TagChip(text: $0) }
            }
            .font(.system(size: 11))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Replaces the legacy episode list + heavy "existing files" block with
    /// the same compact queue-row presentation used in `DetailView`. Each
    /// episode shows a status dot, episode code, headline, percent, thin
    /// progress bar, and any custom-format chips. When the pack has mixed
    /// existing files (variant B/C), each upgrade row also gets a single
    /// inline "↑ replaces …" line with chips.
    private var episodeQueueList: some View {
        let showPerRow = uniformExistingFile == nil
        // Every member of the (now only) `.pack` group shares one physical
        // release — quality + new-format chips would just repeat the pack
        // header on every row, so hide them.
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(group.items) { it in
                TooltipQueueRow(
                    item: it,
                    showExistingFile: showPerRow,
                    showNewFileMeta: false
                )
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
                Text("\(group.memberCount) episodes", bundle: .module)
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

    private var seasonLabel: String? {
        let seasons = Set(group.items.compactMap(\.seasonNumber))
        if seasons.count == 1, let s = seasons.first {
            // %02lld is a zero-padded format specifier — LocalizedStringKey
            // interpolation can't express it, so resolve the format string
            // through the catalog and feed it to String(format:).
            let fmt = String(localized: "Season %02lld", bundle: Bundle.module)
            return String(format: fmt, s)
        }
        if seasons.count > 1 {
            return String(localized: "Multiple seasons", bundle: Bundle.module)
        }
        return nil
    }

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: rep.sizeTotal, countStyle: .file)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, mono: Bool = false, wraps: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label), bundle: .module)
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
    /// When true, render an inline "↑ replaces …" line under the row
    /// for upgrade items, with quality · size · score and existing
    /// custom-format chips wrapping on the same line. Used for season
    /// packs with mixed existing files (Variant B/C) where the per-row
    /// detail is necessary; suppressed when a top-level summary card
    /// already covers it (Variant A).
    var showExistingFile: Bool = false
    /// When false, the row hides quality + new-custom-format chips —
    /// they would otherwise repeat the pack header's identical info on
    /// every episode. Set false for real `.pack` groups where every
    /// member shares one physical release; left true for `.virtual`
    /// bundles where members are independent downloads with potentially
    /// different new-file metadata.
    var showNewFileMeta: Bool = true

    public init(item: QueueItem, showExistingFile: Bool = false, showNewFileMeta: Bool = true) {
        self.item = item
        self.showExistingFile = showExistingFile
        self.showNewFileMeta = showNewFileMeta
    }

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
                // No per-episode upgrade arrow inside the season-pack
                // tooltip — the pack header already says "Upgrade", and
                // either the summary card (Variant A) or the per-row
                // "↑ replaces …" line (Variant B) carries the indigo
                // accent for episodes that need it.
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
            if showNewFileMeta, !item.customFormats.isEmpty || item.customFormatScore != 0 {
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

            if showExistingFile, item.isUpgrade {
                replacesLine
                    .padding(.top, 1)
                    .padding(.leading, 14)
            }
        }
    }

    /// Single wrapping line that combines text + chips for the existing
    /// file: "↑ replaces  720p HDTV · 1.8 GB · +50  [chip] [chip] [chip]".
    /// Lays out via `TooltipFlowLayout` so all of it sits on one row when
    /// it fits and wraps as a unit when it doesn't.
    @ViewBuilder
    private var replacesLine: some View {
        let prefixText = Text("↑ replaces").foregroundStyle(Color.indigo).font(.system(size: 10, weight: .medium))
        let qualityText: Text? = (item.existingQuality?.isEmpty == false)
            ? Text(item.existingQuality!).foregroundStyle(.secondary).font(.system(size: 10))
            : nil
        let sizeText: Text? = (item.existingSize ?? 0) > 0
            ? Text(ByteCountFormatter.string(fromByteCount: item.existingSize!, countStyle: .file))
                .foregroundStyle(.secondary).font(.system(size: 10))
            : nil
        let scoreValue = item.existingCustomFormatScore ?? 0
        let scoreText: Text? = scoreValue != 0
            ? Text("\(scoreValue > 0 ? "+" : "")\(scoreValue)")
                .foregroundStyle(scoreValue > 0 ? Color.green : Color.red)
                .font(.system(size: 10, weight: .semibold))
            : nil
        let dot = Text("·").foregroundStyle(.tertiary).font(.system(size: 10))

        TooltipFlowLayout(spacing: 4) {
            prefixText
            if let qualityText { qualityText }
            if let sizeText { dot; sizeText }
            if let scoreText { dot; scoreText }
            ForEach(item.existingCustomFormats, id: \.self) { TagChip(text: $0) }
        }
    }

    private var episodeCode: String? {
        guard let s = item.seasonNumber, let e = item.episodeNumber else { return nil }
        return String(format: "S%02dE%02d", s, e)
    }

    private var headline: String {
        var bits: [String] = []
        if let t = item.episodeTitle, !t.isEmpty { bits.append(t) }
        // Quality stays suppressed when the row sits inside a pack — the
        // pack header already shows the single shared quality, so
        // repeating it on every episode just adds noise.
        if showNewFileMeta, let q = item.quality, !q.isEmpty { bits.append(q) }
        return bits.joined(separator: " · ")
    }

    private var trailing: String {
        if item.status == .queued { return "Queued" }
        return "\(Int((item.progress * 100).rounded()))%"
    }
}

