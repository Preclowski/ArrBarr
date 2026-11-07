import SwiftUI

extension QueueTitleGroup {
    /// The verb the group's pause/resume control carries out, and on how many downloads.
    var pauseResumeTitle: Text {
        pauseResumeAction == .pause
            ? Text("Pause all (\(pauseTargets.count))", bundle: .module)
            : Text("Resume all (\(resumeTargets.count))", bundle: .module)
    }
}

/// Collapsible container for many independent downloads of one title; children keep their own controls.
/// Row tap toggles; the title opens DetailView. A film's row doesn't expand: any tap opens its detail.
struct QueueTitleGroupRowView: View {
    let group: QueueTitleGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    var onShowDetail: (() -> Void)? = nil
    var selectionState: RowSelectionState = .hidden
    /// A group that can't be picked stays `.hidden` while the list is selecting, so this says so itself.
    var isSelecting = false
    let onPauseAll: @MainActor () -> Void
    let onResumeAll: @MainActor () -> Void
    let onDeleteAll: @MainActor () -> Void

    @Environment(ConfigStore.self) var configStore
    @Environment(\.queueOffline) private var isOffline
    @State private var isHovering = false
    /// Separate from `isHovering`: hovering the title promises "detail", anywhere else "toggle".
    @State private var titleHovering = false

    private var rep: QueueItem { group.representative }

    private var downloadCountText: String {
        String.localizedStringWithFormat(
            NSLocalizedString("queue.titleGroup.downloadsCount", bundle: .module, comment: ""),
            group.downloadCount
        )
    }

    private func requestDeleteAllConfirm() {
        ConfirmCenter.request(.removeAllDownloads(count: group.downloadCount, locale: configStore.currentLocale, onConfirm: onDeleteAll))
    }

    /// The downloads may sit on different clients, and the app may reach only some of them.
    private var controlGroup: QueueTitleGroup { group.controllable { configStore.canControlDownload($0) } }

    private var canPauseResume: Bool { !isOffline && controlGroup.pauseResumeAction != nil }

    private func requestPauseResumeConfirm(_ action: QueueTitleGroup.PauseResumeAction? = nil) {
        guard let confirm = PendingConfirm.pauseResumeAll(controlGroup, action: action, locale: configStore.currentLocale,
                                                          onPause: onPauseAll, onResume: onResumeAll) else { return }
        ConfirmCenter.request(confirm)
    }

    var body: some View {
        // Poster at the same x as every queue row (alignment across row kinds is a hard rule); one disclosure
        // affordance, a trailing chevron.
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                // Rotation doesn't move the layout, so the front card keeps the shared poster x. Fanned to the
                // right only: the left edge is the one every row shares, and 8° stops short of the title.
                ForEach(Array(stride(from: stackDepth, to: 0, by: -1)), id: \.self) { layer in
                    poster
                        .brightness(-0.12 * Double(layer))
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                                .strokeBorder(.black.opacity(0.3), lineWidth: 0.5)
                        }
                        .rotationEffect(.degrees(4 * Double(layer)), anchor: .bottom)
                        .accessibilityHidden(true)
                }
                poster
                    .posterMarks(watched: rep.watched, library: LibraryMark(downloaded: group.allItems.allSatisfy(\.isUpgrade)),
                                 cornerRadius: Tokens.Radius.chip, ribbonWidth: 7)
                    .overlay(alignment: .bottomTrailing) { countBadge }
                    .modifier(PosterLeavingMark())
                    #if os(macOS)
                    .overlay {
                        // A film's downloads are alternatives, not parts: one click starting them all makes no sense.
                        if !isSelecting && isHovering && canPauseResume && group.isExpandable {
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
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    // Its own tap gesture beats the row's toggle tap.
                    HStack(spacing: 4) {
                        Text(rep.title)
                            .scaledFont(size: 12, weight: .semibold)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        LinkChevron(size: 9)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onShowDetail?() }
                    // Lights only on the title itself where the row-wide gesture is the toggle.
                    .environment(\.linkRowHovering, group.isExpandable ? titleHovering : isHovering)
                    #if os(macOS)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { titleHovering = hovering }
                    }
                    #endif

                    Spacer(minLength: 4)
                }

                HStack(spacing: 4) {
                    if let seasonText {
                        Text(seasonText)
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                        Text(verbatim: "·")
                            .scaledFont(size: 11)
                            .foregroundStyle(.tertiary)
                    }
                    LiveProgress(group: group) { progress in
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                    }
                        .scaledFont(size: 11, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                    if totalSize > 0 {
                        Text(verbatim: "·")
                            .scaledFont(size: 11)
                            .foregroundStyle(.tertiary)
                        Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                }

                LiveProgress(group: group) { progress in
                    ThinProgressBar(progress: progress, tint: group.aggregateStatus.tint, height: 6,
                                    flowing: group.allItems.contains { $0.status == .downloading })
                }
            }

            if group.isExpandable {
                Image(systemName: "chevron.down")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(isHovering && !titleHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Tokens.Spacing.queueRowH)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if group.isExpandable { onToggle() } else { onShowDetail?() }
        }
        #if os(macOS)
        // A film's downloads aren't listed here, so the tooltip speaks for the one with a problem.
        .hoverTooltip(enabled: !group.isExpandable, hovering: $isHovering.animation(.easeInOut(duration: 0.15))) {
            let item = group.downloads.first { !$0.statusMessages.isEmpty } ?? rep
            QueueItemTooltip(item: item, apiKey: item.posterRequiresAuth ? configStore.config(for: item.source).apiKey : nil)
        }
        #endif
        .contextMenu {
            if !isOffline {
                let control = controlGroup
                if !control.pauseTargets.isEmpty {
                    Button { requestPauseResumeConfirm(.pause) } label: {
                        Label { Text("Pause all (\(control.pauseTargets.count))", bundle: .module) } icon: { Image(systemName: "pause.fill") }
                    }
                }
                if !control.resumeTargets.isEmpty {
                    Button { requestPauseResumeConfirm(.resume) } label: {
                        Label { Text("Resume all (\(control.resumeTargets.count))", bundle: .module) } icon: { Image(systemName: "play.fill") }
                    }
                }
            }
            QueueHideMenuItem(items: group.allItems)
            if !isOffline {
                Button(role: .destructive) {
                    requestDeleteAllConfirm()
                } label: {
                    Label { Text("Remove all (\(group.downloadCount))", bundle: .module) } icon: { Image(systemName: "trash") }
                }
                // The title's, like the poster tap.
                if onShowDetail != nil {
                    Section {
                        DetailEntryMenuItems(target: rep.seasonContext(), webURL: arrWebURL(for: rep, in: configStore))
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        // The badge is a bare number, so VoiceOver gets the whole phrase here.
        .accessibilityValue(Text(verbatim: "\(downloadCountText), \(group.aggregateProgress.formatted(.percent.precision(.fractionLength(0))))"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selectionState == .selected ? .isSelected : [])
        .accessibilityHint(group.isExpandable
                           ? Text(isExpanded ? "Collapse section" : "Expand section", bundle: .module)
                           : Text("Show download details", bundle: .module))
        // The hover and swipe controls are out of VoiceOver's reach.
        .accessibilityActions {
            if canPauseResume {
                Button { requestPauseResumeConfirm() } label: { controlGroup.pauseResumeTitle }
            }
        }
    }

    #if os(macOS)
    /// A single row's control, except that one click reaches every download, so it asks first.
    private var posterControl: some View {
        Button { requestPauseResumeConfirm() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .fill(.black.opacity(0.5))
                LiveProgress(group: group) { progress in
                    DownloadProgressRing(
                        systemName: controlGroup.pauseResumeAction?.symbol ?? "pause.fill",
                        progress: progress,
                        diameter: 26,
                        lineWidth: 2
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .help(controlGroup.pauseResumeTitle)
        .accessibilityLabel(controlGroup.pauseResumeTitle)
    }
    #endif

    private var poster: some View {
        PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: rep.source), cornerRadius: Tokens.Radius.chip) {
            RemotePoster(
                url: rep.posterURL,
                apiKey: rep.posterRequiresAuth ? configStore.config(for: rep.source).apiKey : nil,
                tier: .icon,
                size: posterSize,
                cornerRadius: Tokens.Radius.chip,
                fallbackSymbol: rep.source.symbol
            )
        }
    }

    /// Cards peeking out behind the poster: a hint of the stack, not a count.
    private var stackDepth: Int { min(group.downloadCount - 1, 2) }

    private var countBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.fill")
                .scaledFont(size: 7, weight: .semibold)
            Text(verbatim: "\(group.downloadCount)")
                .scaledFont(size: 9, weight: .semibold, monospacedDigit: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        // A literal, not `Color.black`: the menu-bar panel blends SwiftUI's named colours with light art.
        .background(Color(.sRGB, white: 0, opacity: 0.72), in: Capsule())
        .fixedSize()
        .padding(2.5)
        .help(Text(verbatim: downloadCountText))
        .accessibilityHidden(true)
    }

    private var posterSize: CGSize {
        switch rep.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 40, height: 60)
        case .lidarr: return CGSize(width: 40, height: 40)
        }
    }
    private var totalSize: Int64 { group.totalSize }

    /// Series groups are keyed per season, so the representative's season is the group's.
    private var seasonText: String? {
        guard rep.source == .sonarr, let season = rep.seasonNumber else { return nil }
        return EpisodeCode.paddedSeasonName(season)
    }
}
