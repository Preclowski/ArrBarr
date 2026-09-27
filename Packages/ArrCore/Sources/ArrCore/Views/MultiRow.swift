import SwiftUI

/// One row of a detail's multi-download list, laid out like a queue row, with the
/// pause/resume ring in the poster slot (cancel lives in the context menu).
struct MultiRow: View {
    let item: QueueItem
    /// Nil keeps the row passive.
    var onTap: (() -> Void)? = nil
    var onPause: (() -> Void)? = nil
    var onResume: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var showHoverPopover = false
    @State private var hoverTask: Task<Void, Never>?
    #if os(iOS)
    @State private var showDeleteConfirm = false
    #endif

    private func requestDeleteConfirm() {
        guard onDelete != nil else { return }
        #if os(macOS)
        // `.confirmationDialog` steals key focus from the MenuBarExtra panel, which dismisses it.
        // The ConfirmCenter listener lives in PopoverContentView, macOS only…
        ConfirmCenter.request(PendingConfirm(
            title: "Remove this download?",
            message: "This will remove the download from the client.",
            confirmLabel: "Remove",
            isDestructive: true,
            onConfirm: onDelete ?? {}
        ))
        #else
        // …so iOS uses the native sheet; a ConfirmCenter request there would never confirm.
        showDeleteConfirm = true
        #endif
    }

    // A queued item gets "play" too: `QueueViewModel.resume` force-starts it.
    private var canPauseResume: Bool {
        item.status == .downloading || item.status == .paused || item.status == .queued
    }

    private var showsPlay: Bool {
        item.isPaused || item.status == .queued
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            controlColumn
            VStack(alignment: .leading, spacing: 4) {
                // No title line: the release name lives in the hover tooltip.
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
        .padding(.vertical, 4)
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        // Not a disabled Button: that greyed out movie lists with no drill target.
        .modifier(RowTapToOpen(action: onTap))
        .contextMenu {
            if canPauseResume {
                if showsPlay, let onResume {
                    Button { onResume() } label: {
                        Label { Text("queue.resume.button", bundle: .module) } icon: { Image(systemName: "play.fill") }
                    }
                } else if !showsPlay, let onPause {
                    Button { onPause() } label: {
                        Label { Text("queue.pause.button", bundle: .module) } icon: { Image(systemName: "pause.fill") }
                    }
                }
            }
            if onDelete != nil {
                Button(role: .destructive) {
                    requestDeleteConfirm()
                } label: {
                    Label { Text("queue.removeFromQueue.button", bundle: .module) } icon: { Image(systemName: "trash") }
                }
            }
        }
        #if os(iOS)
        .confirmationDialog(
            Text("Remove this download?", bundle: .module),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) { onDelete?() } label: {
                Text("Remove", bundle: .module)
            }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("This will remove the download from the client.", bundle: .module)
        }
        #endif
        #if os(macOS)
        // Anchored .leading so the tooltip floats out on the right side of the row.
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if !Task.isCancelled, isHovering { showHoverPopover = true }
                }
            } else {
                showHoverPopover = false
            }
        }
        .tooltipPopover(isPresented: $showHoverPopover, arrowEdge: .leading) {
            QueueItemTooltip(item: item)
        }
        #endif
    }

    @ViewBuilder
    private var controlColumn: some View {
        HStack(spacing: 4) {
            if canPauseResume, showsPlay ? onResume != nil : onPause != nil {
                Button {
                    if showsPlay { onResume?() } else { onPause?() }
                } label: {
                    // No dark disc: it exists for contrast over artwork and reads as a blob here.
                    LiveProgress(item: item) { progress in
                        DownloadProgressRing(
                            systemName: showsPlay ? "play.fill" : "pause.fill",
                            progress: progress,
                            diameter: 24,
                            lineWidth: 2,
                            tint: .primary
                        )
                    }
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(showsPlay
                      ? Text("queue.resume.button", bundle: .module)
                      : Text("queue.pause.button", bundle: .module))
                .accessibilityLabel(showsPlay
                                    ? Text("queue.resume.button", bundle: .module)
                                    : Text("queue.pause.button", bundle: .module))
            }
        }
    }
}
