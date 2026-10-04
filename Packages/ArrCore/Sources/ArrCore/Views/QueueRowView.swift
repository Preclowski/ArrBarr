import SwiftUI

public extension QueueItem.Status {
    var tint: Color {
        switch self {
        case .paused: return .orange
        // Muted amber: waiting, neither active nor stopped.
        case .queued: return Color(hue: 0.09, saturation: 0.42, brightness: 0.72)
        case .failed, .warning: return .red
        case .completed: return .green
        case .importing: return .purple
        default: return .blue
        }
    }
}

extension QueueItem {
    var canPauseResume: Bool { status == .downloading || status == .paused || status == .queued }

    /// A queued item gets "play" too; for it that force-starts the download.
    var showsPlay: Bool { isPaused || status == .queued }

    /// The verb the play/pause control carries out.
    var pauseResumeTitle: Text {
        if status == .queued { return Text("queue.startNow.button", bundle: .module) }
        return isPaused ? Text("queue.resume.button", bundle: .module) : Text("queue.pause.button", bundle: .module)
    }
}

/// With a nil action the gesture is omitted, not a no-op, so it doesn't swallow the click
/// `List(selection:)` needs in multi-select mode.
struct RowTapToOpen: ViewModifier {
    let action: (() -> Void)?
    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

enum RowSelectionState { case hidden, unselected, selected }

struct SelectionCircle: View {
    let selected: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                .fill(.black.opacity(selected ? 0.45 : 0.30))
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .scaledFont(size: 20)
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white))
        }
        .contentShape(Rectangle())
        // The row already publishes the `.isSelected` trait.
        .accessibilityHidden(true)
    }
}

struct QueueRowView: View {
    let item: QueueItem

    /// Series rows fold the episode into the title so every row stays one line tall.
    private var rowTitle: String {
        if let sub = item.subtitle, !sub.isEmpty {
            return "\(item.title) · \(sub)"
        }
        return item.title
    }

    /// Closures instead of an observed view-model so the row re-renders only when its `item` changes.
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: @MainActor () -> Void
    var onShowDetail: (() -> Void)? = nil
    var selectionState: RowSelectionState = .hidden
    @Environment(ConfigStore.self) var configStore
    /// Set by surfaces with a permanent detail pane, which don't need the long-hover tooltip.
    @Environment(\.queueOffline) private var isOffline
    @State private var isHovering = false

    /// Goes through ConfirmCenter because an inline `.overlay` clips the card to the row and truncates labels.
    private func requestDeleteConfirm() {
        ConfirmCenter.request(PendingConfirm(
            title: "Remove this download?",
            message: "This will remove the download from the client.",
            confirmLabel: "Remove",
            isDestructive: true,
            onConfirm: onDelete
        ))
    }

    private var canControl: Bool { configStore.canControlDownload(item) }

    private var canPauseResume: Bool { item.canPauseResume }
    private var showsPlay: Bool { item.showsPlay }
    private var pauseResumeTitle: Text { item.pauseResumeTitle }

    private func togglePause() {
        if showsPlay { onResume() } else { onPause() }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: item.source), cornerRadius: Tokens.Radius.chip) {
                RemotePoster(
                    url: item.posterURL,
                    apiKey: item.posterRequiresAuth ? apiKeyForSource : nil,
                    tier: .icon,
                    size: posterSize,
                    cornerRadius: Tokens.Radius.chip,
                    fallbackSymbol: item.source.symbol
                )
            }
            // Before the hover / selection overlays: the wedge is part of the artwork.
            // An upgrade already has a file.
            .posterMarks(watched: item.watched, library: LibraryMark(downloaded: item.isUpgrade),
                         cornerRadius: Tokens.Radius.chip, ribbonWidth: 7)
            .modifier(PosterLeavingMark())
            // macOS: pause/resume lives on the poster; cancelling a download is deliberately not in the row.
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
                        Text(rowTitle)
                            .scaledFont(size: 12)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // Hidden from VoiceOver: the row's `.isButton` trait and hint say the same.
                        LinkChevron(size: 9)
                            .accessibilityHidden(true)

                        Spacer(minLength: 4)

                        MediaBadgeCluster(isUpgrade: item.isUpgrade)
                    }

                }

                DownloadProgressCard(
                    item: item,
                    showUpgradeDiff: false,
                    showHeader: true,
                    compactSpec: true
                )

                if !item.customFormats.isEmpty || item.customFormatScore != 0 {
                    QueueRowFormatStrip(
                        formats: item.customFormats,
                        score: item.customFormatScore,
                        baseline: item.existingCustomFormatScore
                    )
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.queueRowH)
        .padding(.vertical, 6)
        // ContentShape + tap before the hover overlay, or the row tap swallows the overlay's icon clicks.
        .contentShape(Rectangle())
        // Multi-select passes `onShowDetail: nil`, dropping the gesture so the List's selection click works.
        .modifier(RowTapToOpen(action: onShowDetail))
        // One element, not a dozen fragments; the row is a bare tap gesture, so it must say it's tappable.
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(max(0.0, min(1.0, item.progress)), format: .percent.precision(.fractionLength(0))))
        .accessibilityAddTraits(onShowDetail != nil ? .isButton : [])
        .accessibilityAddTraits(selectionState == .selected ? .isSelected : [])
        .accessibilityHint(onShowDetail != nil
                           ? Text("Show download details", bundle: .module)
                           : Text(verbatim: ""))
        // The hover and swipe controls are out of VoiceOver's reach; these are its way to them.
        .accessibilityActions {
            if !isOffline {
                if canControl && canPauseResume {
                    Button(action: togglePause) { pauseResumeTitle }
                }
                Button(action: requestDeleteConfirm) { Text("queue.removeFromQueue.button", bundle: .module) }
            }
        }
        .contextMenu {
            if !isOffline {
                if canControl && canPauseResume {
                    Button(action: togglePause) {
                        Label { pauseResumeTitle } icon: { Image(systemName: showsPlay ? "play.fill" : "pause.fill") }
                    }
                }
            }
            QueueHideMenuItem(items: [item])
            if !isOffline {
                Button(role: .destructive) {
                    requestDeleteConfirm()
                } label: {
                    Label { Text("queue.removeFromQueue.button", bundle: .module) } icon: { Image(systemName: "trash") }
                }
                Section {
                    DetailEntryMenuItems(target: item, webURL: arrWebURL(for: item, in: configStore))
                }
            }
        }
        // Hover-only affordances are macOS-only; on iOS the tooltip popover would render as a sheet.
        #if os(macOS)
        .hoverTooltip(hovering: $isHovering.animation(.easeInOut(duration: 0.15))) {
            QueueItemTooltip(
                item: item,
                apiKey: item.posterRequiresAuth ? apiKeyForSource : nil
            )
        }
        #endif
        .environment(\.linkRowHovering, isHovering)
    }

    // MARK: - Poster helpers

    private var posterSize: CGSize {
        switch item.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 40, height: 60)
        case .lidarr: return CGSize(width: 40, height: 40)
        }
    }

    private var apiKeyForSource: String? {
        configStore.config(for: item.source).apiKey
    }

    // MARK: - Actions

    #if os(macOS)
    /// No delete button on macOS; iOS uses swipe actions (see QueueListView).
    @ViewBuilder
    private var posterControl: some View {
        Button(action: togglePause) {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .fill(.black.opacity(0.5))
                LiveProgress(item: item) { progress in
                    DownloadProgressRing(
                        systemName: showsPlay ? "play.fill" : "pause.fill",
                        progress: progress,
                        diameter: 26,
                        lineWidth: 2
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .help(pauseResumeTitle)
        // `.help` is a tooltip, not a label; without this the button announces as "play fill".
        .accessibilityLabel(pauseResumeTitle)
    }
    #endif
}

// MARK: - Custom-format strip (queue rows)

/// Shared by `QueueRowView` and `QueueGroupRowView` so the score sits in the same spot.
/// Chips stay on one line and overflow fades out.
struct QueueRowFormatStrip: View {
    let formats: [String]
    let score: Int
    let baseline: Int?

    var body: some View {
        HStack(spacing: 6) {
            // A horizontal ScrollView takes the proposed width; `.fixedSize()` would widen each row to its tags.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(formats, id: \.self) { tag in
                        TagChip(text: tag, color: .secondary)
                    }
                }
            }
            .scrollDisabled(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1.0),
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            if score != 0 {
                ScoreLabel(score: score, baseline: baseline, size: 10)
            }
        }
    }
}

// MARK: - Rich tooltip

struct QueueItemTooltip: View {
    let item: QueueItem
    var apiKey: String? = nil
    @Environment(ConfigStore.self) var configStore

    var body: some View {
        MediaTooltipChrome(
            title: item.title,
            subtitle: item.subtitle,
            posterURL: item.posterURL,
            posterRequiresAuth: apiKey != nil,
            apiKey: apiKey,
            posterSize: MediaTooltipChrome<EmptyView>.posterSize(for: item.source),
            blurred: configStore.shouldBlurPoster(for: item.source),
            fallbackSymbol: item.source.symbol,
            contextChip: item.downloadClient.map { AnyView(DownloadClientLabel(name: $0)) },
            statusChip: AnyView(MediaBadgeCluster(isUpgrade: item.isUpgrade))
        ) {
            tooltipContent
        }
    }

    @ViewBuilder
    private var tooltipContent: some View {
        // Upgrades use the side-by-side `UpgradeDiffView`; the grid keeps only what it doesn't cover.
        if item.isUpgrade {
            UpgradeDiffView(item: item, showFilenames: true)
        }
        TooltipInfoGrid(lines: infoLines)

        if !item.isUpgrade, !item.customFormats.isEmpty || item.customFormatScore != 0 {
            customFormatChipStrip(
                tags: item.customFormats,
                score: item.customFormatScore != 0 ? item.customFormatScore : nil
            )
        }
        // Upgrades render both filenames inside `UpgradeDiffView`.
        if !item.isUpgrade {
            TooltipFileName(name: item.releaseName)
        }
    }

    private var infoLines: [TooltipInfoLine] {
        var lines: [TooltipInfoLine] = []
        if !item.isUpgrade {
            if let q = item.quality, !q.isEmpty {
                lines.append(TooltipInfoLine(labelKey: "Quality", value: q))
            }
            lines.append(TooltipInfoLine(labelKey: "Size", value: sizeString))
        }
        if let indexer = item.indexer, !indexer.isEmpty {
            lines.append(TooltipInfoLine(labelKey: "Indexer", value: indexer))
        }
        return lines
    }

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file)
    }
}

// MARK: - Shared row chrome
// SwiftUI's linear `ProgressView` ignores `.frame(height:)`, so every progress bar goes through this.
struct ThinProgressBar: View {
    let progress: Double
    /// Status tint: colour is what makes a paused row stand out from a downloading one.
    var tint: Color = .primary
    var height: CGFloat = 3

    init(progress: Double, tint: Color = .primary, height: CGFloat = 3) {
        self.progress = progress
        self.tint = tint
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.primary.opacity(0.12))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(tint)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Download progress", bundle: .module))
        .accessibilityValue(Text(max(0.0, min(1.0, progress)), format: .percent.precision(.fractionLength(0))))
    }
}

