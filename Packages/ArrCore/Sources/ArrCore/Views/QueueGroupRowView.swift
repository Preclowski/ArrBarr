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
    /// Multi-select state — `.hidden` = no overlay; otherwise the selection
    /// circle is drawn over the poster (a pack row selects the whole pack).
    var selectionState: RowSelectionState = .hidden

    @EnvironmentObject var configStore: ConfigStore
    /// True when the host already has a permanent detail pane (desktop
    /// window). Suppresses the long-hover tooltip popover.
    @Environment(\.suppressRowTooltip) private var suppressRowTooltip
    /// True when the whole arr stack is unreachable — hide the mutating
    /// controls (they'd fail without a live LAN connection).
    @Environment(\.queueOffline) private var isOffline
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

    /// See QueueRowView.canControl — pause/resume need a configured AND
    /// reachable download client (they bypass the arr); a `.down` client hides
    /// them so the user isn't offered an action that can't reach home.
    private var canControl: Bool {
        // See QueueRowView.canControl — demo serves the action from fixtures.
        if DemoMode.isActive { return true }
        guard let kind = configStore.selectedDownloadClient(for: rep.downloadProtocol) else { return false }
        if case .down = ConnectionHealth.shared.state(for: .arr(kind)) { return false }
        return true
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
                    tier: .icon,
                    size: CGSize(width: 40, height: 60),
                    cornerRadius: Tokens.Radius.chip,
                    fallbackSymbol: "tv"
                )
            }
            // macOS: pause/resume on the poster (hover-revealed); no delete in
            // the list — same treatment as QueueRowView. Suppressed while
            // selecting — the poster is the checkbox then.
            #if os(macOS)
            .overlay {
                if selectionState == .hidden && isHovering && canControl && canPauseResume && !isOffline {
                    posterControl.transition(.opacity)
                }
            }
            #endif
            .overlay {
                if selectionState != .hidden {
                    SelectionCircle(selected: selectionState == .selected)
                        .transition(.opacity)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(rep.title)
                            .scaledFont(size: 12)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // Chevron next to title — same drill-in
                        // affordance as QueueRowView. Hidden from VoiceOver;
                        // the row's `.isButton` trait carries it instead.
                        LinkChevron(size: 9)
                            .accessibilityHidden(true)

                        Spacer(minLength: 4)

                        // Upgrade/New badge on the title line's trailing edge —
                        // matches QueueRowView (no room in the card's status row).
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
                    showUpgradeDiff: false,
                    showHeader: true,
                    compactSpec: true
                )

                // Same custom-format strip + trailing score as QueueRowView —
                // a pack is one physical release, so the rep's formats/score
                // describe the whole row. Keeps the score in the same spot
                // across single and pack rows.
                if !rep.customFormats.isEmpty || rep.customFormatScore != 0 {
                    QueueRowFormatStrip(
                        formats: rep.customFormats,
                        score: rep.customFormatScore,
                        baseline: rep.existingCustomFormatScore
                    )
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.queueRowH)
        .padding(.vertical, 6)
        // No row hover-tint background (poster reveals pause/resume on hover).
        // ContentShape/onTapGesture before the hover affordances so the
        // overlay's own buttons receive clicks instead of the row
        // tap-gesture swallowing them.
        .contentShape(Rectangle())
        // Drop the open-detail tap when there's no target (queue multi-select
        // mode) so it doesn't swallow the List's selection click.
        .modifier(RowTapToOpen(action: onShowDetail))
        // Same treatment as QueueRowView: one element instead of a stream of
        // fragments, the pack's *aggregate* completion as the value (that's
        // what the bar draws), and an explicit button trait because the row
        // is a tap gesture rather than a Button.
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(aggregateProgress, format: .percent.precision(.fractionLength(0))))
        .accessibilityAddTraits(onShowDetail != nil ? .isButton : [])
        .accessibilityAddTraits(selectionState == .selected ? .isSelected : [])
        .accessibilityHint(onShowDetail != nil
                           ? Text("Show download details", bundle: .module)
                           : Text(verbatim: ""))
        .contextMenu {
            // Offline → no mutating menu items; the header chip explains why.
            if !isOffline {
                if canControl && canPauseResume {
                    Button {
                        if showsPlay { onResume() } else { onPause() }
                    } label: {
                        if rep.status == .queued {
                            Label { Text("queue.startNow.button", bundle: .module) } icon: { Image(systemName: "play.fill") }
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
                    Label { Text("queue.removeFromQueue.button", bundle: .module) } icon: { Image(systemName: "trash") }
                }
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

    private var episodeCountText: String {
        String.localizedStringWithFormat(NSLocalizedString("unit.episodes", bundle: .module, comment: ""), group.memberCount)
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
                DownloadProgressRing(
                    systemName: showsPlay ? "play.fill" : "pause.fill",
                    progress: aggregateProgress,
                    diameter: 26,
                    lineWidth: 2
                )
            }
        }
        .buttonStyle(.plain)
        .help(rep.status == .queued
              ? Text("queue.startNow.button", bundle: .module)
              : (rep.isPaused ? Text("queue.resume.button", bundle: .module) : Text("queue.pause.button", bundle: .module)))
        // `.help` is a tooltip, not a label — the glyph alone would
        // announce as "play fill" / "pause fill".
        .accessibilityLabel(rep.status == .queued
                            ? Text("queue.startNow.button", bundle: .module)
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
        // Shared tooltip chrome — see MediaTooltipChrome.
        MediaTooltipChrome(
            title: rep.title,
            posterURL: rep.posterURL,
            posterRequiresAuth: apiKey != nil,
            apiKey: apiKey,
            blurred: configStore.shouldBlurPoster(for: rep.source),
            fallbackSymbol: "tv",
            contextChip: rep.downloadClient.map { AnyView(DownloadClientLabel(name: $0, size: 10)) },
            // Same corner grammar as the single-item tooltip: the Upgrade
            // badge lives in the header, not as an indigo banner over the
            // diff. Only when the whole pack is one uniform upgrade — a
            // mixed pack keeps its per-episode treatment below.
            statusChip: uniformExistingFile != nil
                ? AnyView(MediaBadgeCluster(isUpgrade: true, size: .medium))
                : nil
        ) {
            tooltipContent
        }
    }

    @ViewBuilder
    private var tooltipContent: some View {
            // Season · episode-count line (localized plural lives in Text
            // interpolation, so it stays a view, not a chrome subtitle string).
            HStack(spacing: 4) {
                if let label = seasonLabel {
                    Text(label)
                    SeparatorDot()
                }
                Text("\(group.memberCount) episodes", bundle: .module)
            }
            .scaledFont(size: 11)
            .foregroundStyle(.secondary)

            // Variant A — every upgrade episode is replacing the same kind of
            // file, so the pack reads as ONE upgrade. Same layout as the
            // single-item tooltip: bare side-by-side diff first, then the info
            // grid with only what the diff doesn't cover (indexer).
            if let uniform = uniformExistingFile {
                replacesSummary(uniform: uniform)
            }

            TooltipInfoGrid(lines: infoLines)

            // Upgrades get their gained/lost/kept chips from the diff above —
            // only a non-uniform pack still needs the plain strip.
            if uniformExistingFile == nil,
               !rep.customFormats.isEmpty || rep.customFormatScore != 0 {
                customFormatChipStrip(
                    tags: rep.customFormats,
                    score: rep.customFormatScore != 0 ? rep.customFormatScore : nil
                )
            }

            // No file names anywhere in this tooltip: a pack is one release
            // replacing N files, so the release name plus N on-disk names is
            // a wall of near-identical mono text under a card whose job is
            // the season summary. The single-item tooltip and the detail view
            // still name files — that's where one download means one name.

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

    /// The pack's upgrade diff — identical treatment to the single-item
    /// tooltip: no banner, no tinted card, just the side-by-side comparison
    /// (current → incoming) at the top of the content column. The header's
    /// Upgrade badge and the "N episodes" line already say what the old
    /// indigo "replacing all N episodes" caption said.
    @ViewBuilder
    private func replacesSummary(uniform: ExistingFingerprint) -> some View {
        let rep = group.representative
        // Built from the pack's uniform existing fingerprint vs the shared
        // incoming release. The incoming side carries the pack size; the
        // current side has none, since the pack replaces N distinct files.
        // No file names (`showFilenames: false`) — see tooltipContent.
        UpgradeDiffView(
            current: .init(quality: uniform.quality, score: uniform.score, size: nil, formats: uniform.formats),
            incoming: .init(quality: rep.quality,
                            score: rep.customFormatScore,
                            size: rep.sizeTotal > 0 ? rep.sizeTotal : nil,
                            formats: rep.customFormats)
        )
    }

    /// Replaces the legacy episode list + heavy "existing files" block with
    /// the same compact queue-row presentation used in `DetailView`. Each
    /// episode shows a status dot, episode code, headline, percent, thin
    /// progress bar, and any custom-format chips. When the pack has mixed
    /// existing files (variant B/C), each upgrade row also gets a single
    /// inline "↑ replaces …" line with chips.
    private var episodeQueueList: some View {
        // Every member of the (now only) `.pack` group shares one physical
        // release — quality + new-format chips would just repeat the pack
        // header on every row, so hide them. The per-episode old file names
        // are hidden too: N mono sub-lines turned the episode list into a
        // paths dump instead of a scannable "01, 02, 03…" contents list.
        VStack(alignment: .leading, spacing: 4) {
            ForEach(group.items) { it in
                TooltipQueueRow(item: it, showNewFileMeta: false)
            }
        }
    }


    private var infoLines: [TooltipInfoLine] {
        var lines: [TooltipInfoLine] = []
        // Quality / Size only when there's no upgrade diff above — otherwise
        // the incoming quality and pack size already live in it, and repeating
        // them under the comparison is what made the pack read as "spec first,
        // diff second" instead of a plain upgrade.
        if uniformExistingFile == nil {
            if let q = rep.quality, !q.isEmpty {
                lines.append(TooltipInfoLine(labelKey: "Quality", value: q))
            }
            lines.append(TooltipInfoLine(labelKey: "Size", value: sizeString))
        }
        if let indexer = rep.indexer, !indexer.isEmpty {
            lines.append(TooltipInfoLine(labelKey: "Indexer", value: indexer))
        }
        return lines
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

}

/// Compact queue row used inside the season-pack tooltip. Mirrors the
/// detail-view multi-row look: status icon, episode code, headline,
/// percent, thin progress bar and custom-format chips.
public struct TooltipQueueRow: View {
    let item: QueueItem
    /// When false, the row hides quality + new-custom-format chips —
    /// they would otherwise repeat the pack header's identical info on
    /// every episode. Set false for real `.pack` groups where every
    /// member shares one physical release; left true for `.virtual`
    /// bundles where members are independent downloads with potentially
    /// different new-file metadata.
    var showNewFileMeta: Bool = true

    public init(item: QueueItem, showNewFileMeta: Bool = true) {
        self.item = item
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
                scoreView
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                ZStack(alignment: .leading) {
                    GeometryReader { geo in
                        LiveProgress(item: item) { progress in
                            Rectangle()
                                .fill(item.status.tint.opacity(0.16))
                                .frame(width: geo.size.width * max(0.02, min(1, progress)))
                        }
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

    /// The incoming file's own score, like every other inline gutter.
    /// This row used to show the DELTA alone — a bare "+125" that looked
    /// exactly like the release list's absolute "+125" and meant something
    /// else entirely.
    @ViewBuilder
    private var scoreView: some View {
        ScoreLabel(score: item.customFormatScore,
                   baseline: item.existingCustomFormatScore, size: 10)
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

