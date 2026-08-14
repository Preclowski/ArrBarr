import SwiftUI

/// Collapsible header for a by-title queue group (`QueueTitleGroup`) — many
/// independent downloads of one series / movie / album bundled under one row.
///
/// Unlike the removed "virtual bundles", this is a *container*, not a merged
/// download: the children are the real queue rows with their own controls,
/// and the header is honest about being an aggregate ("12 downloads · 43%").
/// Row tap toggles disclosure (the primary intent when a title floods the
/// queue); the poster opens the title's DetailView, whose download section
/// already lists every sibling — that's the "second level".
struct QueueTitleGroupRowView: View {
    let group: QueueTitleGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    var onShowDetail: (() -> Void)? = nil
    /// Bulk actions over every member — explicit fan-out, wired by the list.
    let onPauseAll: () -> Void
    let onResumeAll: () -> Void
    let onDeleteAll: () -> Void

    @EnvironmentObject var configStore: ConfigStore
    /// True when the whole arr stack is unreachable — hide mutating controls.
    @Environment(\.queueOffline) private var isOffline
    /// Row-wide hover — lights the trailing disclosure chevron.
    @State private var isHovering = false
    /// Title-only hover — lights the title's LinkChevron (the drill-in).
    /// Separate from `isHovering` so the two affordances don't light up
    /// together: hovering the title promises "detail", hovering anywhere
    /// else promises "toggle".
    @State private var titleHovering = false

    private var rep: QueueItem { group.representative }

    /// Mirrors QueueRowView.canControl — pause/resume bypass the arr and talk
    /// to the download client, so they need one configured AND not known-down.
    private var canControl: Bool {
        if DemoMode.isActive { return true }
        guard let kind = configStore.selectedDownloadClient(for: rep.downloadProtocol) else { return false }
        if case .down = ConnectionHealth.shared.state(for: .arr(kind)) { return false }
        return true
    }

    private var downloadCountText: String {
        String.localizedStringWithFormat(
            NSLocalizedString("queue.titleGroup.downloadsCount", bundle: .module, comment: ""),
            group.downloadCount
        )
    }

    private func requestDeleteAllConfirm() {
        ConfirmCenter.request(PendingConfirm(
            title: "Cancel \(group.downloadCount) downloads?",
            message: "This will remove every download of this title from the client.",
            confirmLabel: "Cancel downloads",
            cancelLabel: "Keep downloads",
            isDestructive: true,
            onConfirm: onDeleteAll
        ))
    }

    var body: some View {
        // Variant B ("natywny trailing chevron"): poster at the exact same x
        // as every normal queue row (alignment across row kinds is a hard
        // rule), count as a chip on the title line, and ONE disclosure
        // affordance — a trailing chevron at the row's right edge that
        // rotates open, the standard macOS disclosure grammar.
        HStack(alignment: .center, spacing: 10) {
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: rep.source), cornerRadius: Tokens.Radius.chip) {
                RemotePoster(
                    url: rep.posterURL,
                    apiKey: rep.posterRequiresAuth ? configStore.serviceConfig(for: rep.source).apiKey : nil,
                    tier: .icon,
                    size: posterSize,
                    cornerRadius: Tokens.Radius.chip,
                    fallbackSymbol: rep.source.symbol
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    // Title + LinkChevron = the drill-in to DetailView, same
                    // grammar as a single row's title line. Its own tap
                    // gesture beats the row's toggle tap.
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
                    // LinkChevron lights ONLY while the pointer is on the
                    // title itself — not on row hover like other rows,
                    // because here the row-wide gesture is the toggle, not
                    // the drill-in.
                    .environment(\.linkRowHovering, titleHovering)
                    #if os(macOS)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { titleHovering = hovering }
                    }
                    #endif

                    // Count chip — same visual family as the format chips, so
                    // the group marker doesn't invent a new control kind.
                    TagChip(text: downloadCountText)

                    Spacer(minLength: 4)
                }

                // "43% · 31,5 GB" — aggregate completion + total batch size
                // (the chip above carries the count).
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

                // Same bar as every other queue row (ThinProgressBar via
                // DownloadProgressCard's compact variant) — a different bar
                // style here read as a foreign element.
                LiveProgress(group: group) { progress in
                    ThinProgressBar(progress: progress, tint: aggregateTint, height: 6)
                }
            }

            // THE disclosure affordance — trailing edge, vertically centred,
            // rotating open. Lights up on row hover (anywhere outside the
            // title), telegraphing that a click here toggles.
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
                Button(role: .destructive) {
                    requestDeleteAllConfirm()
                } label: {
                    Label { Text("Remove all (\(group.downloadCount))", bundle: .module) } icon: { Image(systemName: "trash") }
                }
            }
        }
        // One element: "Title, 12 downloads, 43%", button trait + state.
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(group.aggregateProgress, format: .percent.precision(.fractionLength(0))))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(isExpanded ? "Collapse section" : "Expand section", bundle: .module))
    }

    /// Tint for the aggregate bar: active blue while anything is downloading,
    /// paused orange when the whole batch is paused, otherwise the
    /// representative's status colour — same palette as the per-row bars.
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
    /// Sum of every member's total size — the batch's on-disk footprint.
    private var totalSize: Int64 {
        group.allItems.reduce(Int64(0)) { $0 + $1.sizeTotal }
    }
}
