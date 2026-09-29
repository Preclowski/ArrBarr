import SwiftUI

/// A Sonarr season pack: one download that the arr's queue reports as N episode entries
/// sharing a `downloadId`. Rendered as one ordinary row, no expansion.
struct QueueGroupRowView: View {
    let group: QueueGroup
    /// Applied to the representative; every member shares its downloadId, so the arr acts on the whole pack.
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    var onShowDetail: (() -> Void)? = nil
    var selectionState: RowSelectionState = .hidden

    @EnvironmentObject var configStore: ConfigStore
    @Environment(\.queueOffline) private var isOffline
    @State private var isHovering = false

    private func requestDeleteConfirm() {
        ConfirmCenter.request(PendingConfirm(
            title: "Remove this season pack?",
            message: "This will remove the season pack from the client.",
            confirmLabel: "Remove",
            isDestructive: true,
            onConfirm: onDelete
        ))
    }

    private var rep: QueueItem { group.representative }

    private var canControl: Bool { configStore.canControlDownload(rep.downloadProtocol) }

    private var canPauseResume: Bool {
        rep.status == .downloading || rep.status == .paused || rep.status == .queued
    }

    private var showsPlay: Bool {
        rep.isPaused || rep.status == .queued
    }

    var body: some View {
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
            .posterMarks(watched: rep.watched, monitored: nil,
                         cornerRadius: Tokens.Radius.chip, ribbonWidth: 7)
            // Suppressed while selecting: the poster is the checkbox then.
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

                        // Hidden from VoiceOver; the row's `.isButton` trait carries it.
                        LinkChevron(size: 9)
                            .accessibilityHidden(true)

                        Spacer(minLength: 4)

                        MediaBadgeCluster(isUpgrade: rep.isUpgrade)
                    }

                    if let label = seasonLabel {
                        Text(label)
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                }

                DownloadProgressCard(
                    item: rep,
                    progressOverride: aggregateProgress,
                    showUpgradeDiff: false,
                    showHeader: true,
                    compactSpec: true
                )

                // A pack is one release, so the representative's formats/score describe the whole row.
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
        // Before the hover affordances, so the overlay's buttons get clicks instead of the row tap.
        .contentShape(Rectangle())
        // No target in multi-select mode, so the tap doesn't swallow the List's selection click.
        .modifier(RowTapToOpen(action: onShowDetail))
        // One element with the aggregate completion as its value; an explicit button trait
        // because the row is a tap gesture, not a Button.
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(aggregateProgress, format: .percent.precision(.fractionLength(0))))
        .accessibilityAddTraits(onShowDetail != nil ? .isButton : [])
        .accessibilityAddTraits(selectionState == .selected ? .isSelected : [])
        .accessibilityHint(onShowDetail != nil
                           ? Text("Show download details", bundle: .module)
                           : Text(verbatim: ""))
        .contextMenu {
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
            }
            QueueHideMenuItem(items: group.items)
            if !isOffline {
                Button(role: .destructive) {
                    requestDeleteConfirm()
                } label: {
                    Label { Text("queue.removeFromQueue.button", bundle: .module) } icon: { Image(systemName: "trash") }
                }
                // The pack's tap opens the series, so its entries are the series'.
                Section {
                    DetailEntryMenuItems(target: rep.seasonContext(), webURL: arrWebURL(for: rep, in: configStore))
                }
            }
        }
        #if os(macOS)
        .hoverTooltip(hovering: $isHovering.animation(.easeInOut(duration: 0.15))) {
            QueueGroupTooltip(
                group: group,
                apiKey: rep.posterRequiresAuth ? configStore.sonarr.apiKey : nil
            )
        }
        #endif
        .environment(\.linkRowHovering, isHovering)
    }

    // MARK: - Header text

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

    /// Pack members share one download, so any member carries the whole pack's progress.
    private var aggregateProgress: Double { group.representative.progress }

    // MARK: - Actions

    #if os(macOS)
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
        // `.help` is a tooltip, not a label; the glyph alone would announce as "play fill".
        .accessibilityLabel(rep.status == .queued
                            ? Text("queue.startNow.button", bundle: .module)
                            : (rep.isPaused ? Text("queue.resume.button", bundle: .module) : Text("queue.pause.button", bundle: .module)))
    }
    #endif

}

// MARK: - Season pack tooltip

/// Hover popover for a season pack: `QueueItemTooltip` chrome plus the list of episodes it covers.
struct QueueGroupTooltip: View {
    let group: QueueGroup
    var apiKey: String? = nil
    @EnvironmentObject var configStore: ConfigStore

    private var rep: QueueItem { group.representative }

    var body: some View {
        MediaTooltipChrome(
            title: rep.title,
            posterURL: rep.posterURL,
            posterRequiresAuth: apiKey != nil,
            apiKey: apiKey,
            blurred: configStore.shouldBlurPoster(for: rep.source),
            fallbackSymbol: "tv",
            contextChip: rep.downloadClient.map { AnyView(DownloadClientLabel(name: $0)) },
            // Only when the whole pack is one uniform upgrade; a mixed pack keeps per-episode treatment.
            statusChip: uniformExistingFile != nil
                ? AnyView(MediaBadgeCluster(isUpgrade: true))
                : nil
        ) {
            tooltipContent
        }
    }

    @ViewBuilder
    private var tooltipContent: some View {
            // The localized plural lives in Text interpolation, so this stays a view.
            HStack(spacing: 4) {
                if let label = seasonLabel {
                    Text(label)
                    SeparatorDot()
                }
                Text("\(group.memberCount) episodes", bundle: .module)
            }
            .scaledFont(size: 11)
            .foregroundStyle(.secondary)

            // Every upgrading episode replaces the same kind of file, so the pack reads as one upgrade.
            if let uniform = uniformExistingFile {
                replacesSummary(uniform: uniform)
            }

            TooltipInfoGrid(lines: infoLines)

            if uniformExistingFile == nil,
               !rep.customFormats.isEmpty || rep.customFormatScore != 0 {
                customFormatChipStrip(
                    tags: rep.customFormats,
                    score: rep.customFormatScore != 0 ? rep.customFormatScore : nil
                )
            }

            // No file names here: one release replacing N files would be a wall of near-identical paths.

            if !group.items.isEmpty {
                // "Season 0X" when every item shares a season, so rows can show just "01, 02, …".
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

    private struct ExistingFingerprint: Equatable {
        let quality: String
        let score: Int
        let formats: [String]
    }

    private func existingFingerprint(_ item: QueueItem) -> ExistingFingerprint? {
        // Rows without existing-file metadata (fresh adds) neither break nor count toward a uniform match.
        guard item.isUpgrade,
              let q = item.existingQuality, !q.isEmpty
        else { return nil }
        return ExistingFingerprint(
            quality: q,
            score: item.existingCustomFormatScore ?? 0,
            formats: item.existingCustomFormats.sorted()
        )
    }

    /// nil as soon as two upgrade rows differ.
    private var uniformExistingFile: ExistingFingerprint? {
        let prints = group.items.compactMap(existingFingerprint)
        guard !prints.isEmpty else { return nil }
        // One upgrade row among fresh adds reads better with its own replaces line.
        guard prints.count >= 2 else { return nil }
        let first = prints[0]
        guard prints.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    @ViewBuilder
    private func replacesSummary(uniform: ExistingFingerprint) -> some View {
        let rep = group.representative
        // No current-side size: the pack replaces N distinct files.
        UpgradeDiffView(
            current: .init(quality: uniform.quality, score: uniform.score, size: nil, formats: uniform.formats),
            incoming: .init(quality: rep.quality,
                            score: rep.customFormatScore,
                            size: rep.sizeTotal > 0 ? rep.sizeTotal : nil,
                            formats: rep.customFormats)
        )
    }

    private var episodeQueueList: some View {
        // Every member shares one release, so quality and format chips would repeat the header.
        VStack(alignment: .leading, spacing: 4) {
            ForEach(group.items) { it in
                TooltipQueueRow(item: it)
            }
        }
    }

    private var infoLines: [TooltipInfoLine] {
        var lines: [TooltipInfoLine] = []
        // Only without the diff above, which already carries quality and size.
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
            // LocalizedStringKey interpolation can't express `%02lld`, so format through the catalog.
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

struct TooltipQueueRow: View {
    let item: QueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Mirrors `EpisodeRow`: the background fill is the progress bar, tinted like the title.
            HStack(spacing: 6) {
                if let code = episodeCode {
                    Text(code)
                        .scaledFont(size: 11, weight: .semibold, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                }
                Text(headline)
                    .scaledFont(size: 11)
                    .foregroundStyle(item.status.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
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
        }
    }

    /// Absolute score, not the delta: a bare "+125" would look like the release list's absolute score.
    @ViewBuilder
    private var scoreView: some View {
        ScoreLabel(score: item.customFormatScore,
                   baseline: item.existingCustomFormatScore, size: 10)
    }

    private var episodeCode: String? {
        guard let e = item.episodeNumber else { return nil }
        return String(format: "%02d", e)
    }

    private var headline: String {
        item.episodeTitle ?? ""
    }

}

