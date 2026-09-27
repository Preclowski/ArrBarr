import SwiftUI

/// Collapsible container for many independent downloads of one title; children keep their own controls.
/// Row tap toggles; the poster opens DetailView.
struct QueueTitleGroupRowView: View {
    let group: QueueTitleGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    var onShowDetail: (() -> Void)? = nil
    let onPauseAll: () -> Void
    let onResumeAll: () -> Void
    let onDeleteAll: () -> Void

    @EnvironmentObject var configStore: ConfigStore
    @Environment(\.queueOffline) private var isOffline
    @State private var isHovering = false
    /// Separate from `isHovering`: hovering the title promises "detail", anywhere else "toggle".
    @State private var titleHovering = false

    private var rep: QueueItem { group.representative }

    private var canControl: Bool { configStore.canControlDownload(rep.downloadProtocol) }

    private var downloadCountText: String {
        String.localizedStringWithFormat(
            NSLocalizedString("queue.titleGroup.downloadsCount", bundle: .module, comment: ""),
            group.downloadCount
        )
    }

    private func requestDeleteAllConfirm() {
        ConfirmCenter.request(PendingConfirm(
            title: "Remove \(group.downloadCount) downloads?",
            message: "This will remove every download of this title from the client.",
            confirmLabel: "Remove All",
            isDestructive: true,
            onConfirm: onDeleteAll
        ))
    }

    var body: some View {
        // Poster at the same x as every queue row (alignment across row kinds is a hard rule); one disclosure
        // affordance, a trailing chevron.
        HStack(alignment: .center, spacing: 10) {
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
            .posterMarks(watched: rep.watched, monitored: nil,
                         cornerRadius: Tokens.Radius.chip, ribbonWidth: 7)

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
                    // Lights only on the title itself, since the row-wide gesture here is the toggle.
                    .environment(\.linkRowHovering, titleHovering)
                    #if os(macOS)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { titleHovering = hovering }
                    }
                    #endif

                    TagChip(text: downloadCountText)

                    Spacer(minLength: 4)
                }

                HStack(spacing: 4) {
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
                    ThinProgressBar(progress: progress, tint: aggregateTint, height: 6)
                }
            }

            Image(systemName: "chevron.down")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(isHovering && !titleHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Tokens.Spacing.queueRowH)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        #endif
        .contextMenu {
            if !isOffline {
                if canControl {
                    Button(action: onPauseAll) {
                        Label { Text("Pause all (\(group.downloadCount))", bundle: .module) } icon: { Image(systemName: "pause.fill") }
                    }
                    Button(action: onResumeAll) {
                        Label { Text("Resume all (\(group.downloadCount))", bundle: .module) } icon: { Image(systemName: "play.fill") }
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
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(group.aggregateProgress, format: .percent.precision(.fractionLength(0))))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(isExpanded ? "Collapse section" : "Expand section", bundle: .module))
    }

    private var aggregateTint: Color {
        let items = group.allItems
        if items.contains(where: { $0.status == .downloading }) { return QueueItem.Status.downloading.tint }
        if items.allSatisfy({ $0.status == .paused }) { return QueueItem.Status.paused.tint }
        return rep.status.tint
    }

    private var posterSize: CGSize {
        switch rep.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 40, height: 60)
        case .lidarr: return CGSize(width: 40, height: 40)
        }
    }
    private var totalSize: Int64 {
        group.allItems.reduce(Int64(0)) { $0 + $1.sizeTotal }
    }
}
