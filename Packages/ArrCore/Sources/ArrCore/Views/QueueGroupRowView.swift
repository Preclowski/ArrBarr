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
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    private func requestDeleteConfirm() {
        ConfirmCenter.request(PendingConfirm(
            title: "Cancel this download?",
            message: "This will remove the season pack from the client.",
            confirmLabel: "Cancel download",
            cancelLabel: "Keep download",
            isDestructive: true,
            onConfirm: onDelete
        ))
    }

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
        rep.status == .downloading || rep.status == .paused || rep.status == .queued
    }

    private var showsPlay: Bool {
        rep.isPaused || rep.status == .queued
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: rep.source), cornerRadius: Tokens.Radius.chip) {
                RemotePoster(
                    url: rep.posterURL,
                    apiKey: rep.posterRequiresAuth ? configStore.sonarr.apiKey : nil,
                    size: CGSize(width: 40, height: 60),
                    cornerRadius: Tokens.Radius.chip,
                    fallbackSymbol: "tv"
                )
            }
            // macOS: pause/resume on the poster (hover-revealed); no delete in
            // the list — same treatment as QueueRowView.
            #if os(macOS)
            .overlay {
                if isHovering && canControl && canPauseResume {
                    posterControl.transition(.opacity)
                }
            }
            #endif

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(rep.title)
                            .scaledFont(size: 12)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // Chevron next to title — same drill-in
                        // affordance as QueueRowView.
                        LinkChevron(size: 9)

                        Spacer(minLength: 4)

                        // Upgrade/New badge on the title row's trailing
                        // edge — matches QueueRowView (moved out of the
                        // progress card header below).
                        MediaBadgeCluster(isUpgrade: rep.isUpgrade)
                    }

                    if let label = seasonLabel {
                        Text(label)
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Quality dropped from the row — surfaced in the
                    // long-hover tooltip + detail view instead.
                }

                DownloadProgressCard(
                    item: rep,
                    progressOverride: aggregateProgress,
                    fadeTrailing: !(isHovering && canControl),
                    showUpgradeDiff: false,
                    showHeader: true,
                    showBadge: false,
                    compactSpec: true
                )
            }
        }
        .padding(.horizontal, Tokens.Spacing.queueRowH)
        .padding(.vertical, 6)
        // No row hover-tint background (poster reveals pause/resume on hover).
        // ContentShape/onTapGesture before the hover affordances so the
        // overlay's own buttons receive clicks instead of the row
        // tap-gesture swallowing them.
        .contentShape(Rectangle())
        .onTapGesture {
            onShowDetail?()
        }
        .contextMenu {
            if canControl && canPauseResume {
                Button {
                    if showsPlay { onResume() } else { onPause() }
                } label: {
                    if rep.status == .queued {
                        Label { Text("Start now", bundle: .module) } icon: { Image(systemName: "play.fill") }
                    } else if rep.isPaused {
                        Label { Text("queue.resume.button", bundle: .module) } icon: { Image(systemName: "play.fill") }
                    } else {
                        Label { Text("queue.pause.button", bundle: .module) } icon: { Image(systemName: "pause.fill") }
                    }
                }
            }
            Button(role: .destructive) {
                requestDeleteConfirm()
            } label: {
                Label { Text("Remove from queue", bundle: .module) } icon: { Image(systemName: "trash") }
            }
        }
        // macOS-only hover affordances: row tint + 600 ms delayed tooltip.
        // iOS users tap the row to drill into the detail view, which
        // surfaces the same content as the macOS tooltip.
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
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
        .tooltipPopover(isPresented: $showTooltip, arrowEdge: .trailing) {
            QueueGroupTooltip(
                group: group,
                apiKey: rep.posterRequiresAuth ? configStore.sonarr.apiKey : nil,
                locale: configStore.currentLocale
            )
        }
        #endif
        // Light up the drill-in LinkChevron whenever the row is hovered
        // (reuses the existing isHovering, no extra onHover).
        .environment(\.linkRowHovering, isHovering)
        // Confirmation now lives at panel level via ConfirmCenter
        // (see requestDeleteConfirm).
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
        let packLabel = String(localized: "queue.seasonPack.button", bundle: .module)
        if seasons.count == 1, let s = seasons.first {
            let seasonText = String(format: String(localized: "queue.season02lld.button", bundle: .module), s)
            return "\(seasonText) · \(packLabel) · \(episodeCountText)"
        }
        if seasons.count > 1 {
            return "\(String(localized: "queue.multipleSeasons.button", bundle: .module)) · \(packLabel) · \(episodeCountText)"
        }
        return "\(String(localized: "queue.seasonPack.button", bundle: .module)) · \(episodeCountText)"
    }

    /// Used in the alert; same logic as `seasonLabel` but always returns
    /// something readable.
    private var headerLabel: String {
        if let s = seasonLabel { return "\(rep.title) — \(s)" }
        return rep.title
    }

    private var episodeCountText: String {
        String(format: String(localized: "unit.episodes", bundle: .module), group.memberCount)
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

    #if os(macOS)
    /// Pause/resume overlaid on the poster (hover-revealed). No delete button in
    /// the list — same treatment as QueueRowView.posterControl.
    @ViewBuilder
    private var posterControl: some View {
        Button {
            if showsPlay { onResume() } else { onPause() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .fill(.black.opacity(0.5))
                Image(systemName: showsPlay ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .help(rep.status == .queued
              ? Text("Start now", bundle: .module)
              : (rep.isPaused ? Text("queue.resume.button", bundle: .module) : Text("queue.pause.button", bundle: .module)))
    }
    #endif


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
    /// Action cluster pinned at the bottom of the tooltip — see
    @EnvironmentObject var configStore: ConfigStore

    private var rep: QueueItem { group.representative }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: rep.source), cornerRadius: Tokens.Radius.card) {
                RemotePoster(
                    url: rep.posterURL,
                    apiKey: apiKey,
                    size: CGSize(width: 110, height: 165),
                    cornerRadius: Tokens.Radius.card,
                    fallbackSymbol: "tv"
                )
            }
            tooltipContent
        }
        .padding(12)
        .frame(width: 480)
        // See QueueItemTooltip — letting NSPopover's native chrome paint
        // the backdrop instead of `.regularMaterial` keeps tooltip and
        // parent popover visually unified.
    }

    private var tooltipContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
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
                // Header reads "Season 0X" when every queue item shares
                // the same season (the common case — this tooltip
                // *is* a season pack). Falls back to "Episodes" only
                // for the rare mixed-season grouping. Combined with the
                // per-row code dropping S/E prefixes and showing just
                // "01, 02, …", the section now reads as one season's
                // contents instead of repeating "S01" on every line.
                let seasonHeader: Text = {
                    let uniqueSeasons = Set(group.items.compactMap(\.seasonNumber))
                    if uniqueSeasons.count == 1, let s = uniqueSeasons.first {
                        return Text(String(format: NSLocalizedString("queue.season02d.button",
                                                                     bundle: .module,
                                                                     comment: "Tooltip section header"), s))
                    }
                    return Text("queue.episodes.button", bundle: .module)
                }()
                seasonHeader
                    .scaledFont(size: 10, weight: .semibold)
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
        let rep = group.representative
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.doc.fill")
                    .scaledFont(size: 9)
                    .foregroundStyle(.indigo)
                Text("Replacing all \(upgradeCount) episodes", bundle: .module)
                    .scaledFont(size: 9, weight: .semibold)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.indigo)
            }
            // Same side-by-side diff as everywhere else (current → incoming),
            // built from the pack's uniform existing fingerprint vs the shared
            // incoming release.
            UpgradeDiffView(
                current: .init(quality: uniform.quality, score: uniform.score, size: nil, formats: uniform.formats),
                incoming: .init(quality: rep.quality, score: rep.customFormatScore, size: nil, formats: rep.customFormats)
            )
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
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
                    .scaledFont(size: 13, weight: .semibold)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let client = rep.downloadClient {
                    let color = downloadClientColor(client)
                    Text(client)
                        .scaledFont(size: 9, weight: .semibold)
                        .foregroundStyle(color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chip).stroke(color.opacity(0.30), lineWidth: 0.75))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: 4) {
                if let label = seasonLabel {
                    Text(label)
                    SeparatorDot()
                }
                Text("\(group.memberCount) episodes", bundle: .module)
            }
            .scaledFont(size: 11)
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
            let fmt = String(localized: "queue.season02lld.button", bundle: Bundle.module)
            return String(format: fmt, s)
        }
        if seasons.count > 1 {
            return String(localized: "queue.multipleSeasons.button", bundle: Bundle.module)
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
                // Match the detail view's UpgradeDiffTable label
                // typography (semibold secondary) so the tooltip's
                // fact rows read the same as the detail diff.
                .scaledFont(size: 11, weight: .semibold)
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
            // Match `EpisodeRow`'s chrome — the row's background is
            // the progress visualiser (status-tint bar filling
            // `progress` % of the width), title takes the matching
            // status colour so foreground + background share a hue.
            // No standalone progress bar, no leading status icon —
            // the coloured fill carries that information.
            HStack(spacing: 6) {
                if let code = episodeCode {
                    Text(code)
                        .scaledFont(size: 11, weight: .semibold, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                }
                // Per-row Upgrade / New badge dropped — this tooltip
                // is always a season-pack, every episode in the list
                // shares the same upgrade state, so the pack header's
                // badge covers it. Per-row was visual repetition.
                Text(headline)
                    .scaledFont(size: 11)
                    .foregroundStyle(item.status.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                // Score delta replaces the trailing percent — for an
                // active pack download, "+50 vs your existing" is
                // more interesting than a number the progress bar
                // already shows visually.
                scoreDeltaView
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                ZStack(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(item.status.tint.opacity(0.16))
                            .frame(width: geo.size.width * max(0.02, min(1, item.progress)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip))
            )
            if showNewFileMeta, !item.customFormats.isEmpty {
                TooltipFlowLayout(spacing: 3) {
                    ForEach(item.customFormats, id: \.self) { TagChip(text: $0) }
                }
                .padding(.top, 1)
            }
        }
    }

    /// Score delta = new file score − existing file score. Green when
    /// the upgrade gains points, red when it loses, neutral when
    /// equal. Falls back to the raw score when no existing score is
    /// known (fresh download with no replacement target).
    @ViewBuilder
    private var scoreDeltaView: some View {
        if let existing = item.existingCustomFormatScore {
            let delta = item.customFormatScore - existing
            let sign = delta > 0 ? "+" : (delta == 0 ? "±" : "")
            Text(verbatim: "\(sign)\(delta)")
                .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(delta > 0 ? Color.green : (delta < 0 ? Color.red : .secondary))
        } else if item.customFormatScore != 0 {
            let sign = item.customFormatScore > 0 ? "+" : ""
            Text(verbatim: "\(sign)\(item.customFormatScore)")
                .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(item.customFormatScore > 0 ? Color.green : Color.red)
        }
    }

    private var episodeCode: String? {
        // Pack header now carries the season ("Season 0X"), so the
        // per-row code collapses to just the episode number — keeps
        // the row narrow and reads as a list ("01, 02, 03…") instead
        // of stuttering "S01" on every line.
        guard let e = item.episodeNumber else { return nil }
        return String(format: "%02d", e)
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

}

