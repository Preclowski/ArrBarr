import SwiftUI

/// One row inside the multi-item list (two grabs of the same movie/album, or
/// several episodes of one series). Mirrors the queue-list row layout so the
/// detail's download list reads identically to the queue: title line with the
/// Upgrade/New badge, the compact `DownloadProgressCard` (status word + client
/// + quality · size over the progress bar), and the custom-format strip with
/// the score below — except the poster slot on the left holds the row's
/// pause/resume ring instead of artwork (cancel lives in the context menu).
struct MultiRow: View {
    let item: QueueItem
    /// Tap handler — drills the user into the episode detail
    /// overlay. Nil keeps the row passive.
    var onTap: (() -> Void)? = nil
    /// Per-item queue actions rendered as the always-visible control
    /// column in the poster slot (plus the row's context menu).
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
        // Panel-wide inline overlay — `.confirmationDialog` steals key focus
        // from the MenuBarExtra panel, which auto-dismisses it. The listener
        // lives in PopoverContentView, which only exists on macOS…
        ConfirmCenter.request(PendingConfirm(
            title: "Cancel this download?",
            message: "This will remove the download from the client.",
            confirmLabel: "Cancel download",
            cancelLabel: "Keep download",
            isDestructive: true,
            onConfirm: onDelete ?? {}
        ))
        #else
        // …so iOS uses the platform-native sheet instead (same pattern as
        // EpisodeRow) — a ConfirmCenter request there has no listener and
        // the delete would silently never confirm.
        showDeleteConfirm = true
        #endif
    }

    private var canPauseResume: Bool {
        item.status == .downloading || item.status == .paused
    }

    public var body: some View {
        // `.center` so the control column floats vertically centred against
        // the card + chip strip, like the poster centres on a queue row.
        HStack(alignment: .center, spacing: 10) {
            controlColumn
            VStack(alignment: .leading, spacing: 4) {
                // No title line — the release name lives in the hover tooltip;
                // the row leads straight with the status card.
                // Status word + client + quality · size above the 6pt bar —
                // byte-identical chrome to the queue list rows.
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
        // No row background at all — the focused accent wash read as random
        // bluish rows and the hover tint as another shade; the rows are
        // uniform now, like the queue list.
        .contentShape(Rectangle())
        // Tap-to-drill via the same modifier queue rows use — a wrapping
        // Button with `.disabled(onTap == nil)` greyed the whole row out
        // for movie lists (no drill target), which read as "inactive".
        .modifier(RowTapToOpen(action: onTap))
        // Context menu (long-press on iOS, right-click on macOS) mirrors the
        // control column so the actions are reachable both ways.
        .contextMenu {
            if canPauseResume {
                if item.isPaused, let onResume {
                    Button { onResume() } label: {
                        Label { Text("queue.resume.button", bundle: .module) } icon: { Image(systemName: "play.fill") }
                    }
                } else if !item.isPaused, let onPause {
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
            Text("queue.cancelThisDownload.tooltip", bundle: .module),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) { onDelete?() } label: {
                Text("queue.cancelDownload.button", bundle: .module)
            }
            Button(role: .cancel) {} label: { Text("queue.keepDownload.button", bundle: .module) }
        } message: {
            Text("This will remove the download from the client.", bundle: .module)
        }
        #endif
        #if os(macOS)
        // Long-hover rich tooltip — same QueueItemTooltip the queue
        // list rows use, anchored to .leading so it floats out on
        // the *right* side of the row (per user feedback). One
        // tooltip component everywhere = one place to bump styling.
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task { @MainActor in
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
        // Confirmation via ConfirmCenter.shared (see requestDeleteConfirm).
    }

    /// Always-visible pause/resume control occupying the slot where the queue
    /// row draws its poster — to the left of the progress card, wearing the
    /// poster control's progress-ring chrome (tinted adaptively, no scrim).
    @ViewBuilder
    private var controlColumn: some View {
        HStack(spacing: 4) {
            if canPauseResume, item.isPaused ? onResume != nil : onPause != nil {
                Button {
                    if item.isPaused { onResume?() } else { onPause?() }
                } label: {
                    // No dark disc — that backdrop exists to guarantee
                    // contrast over poster artwork; on the plain row it read
                    // as a black blob. The ring tints adaptively instead.
                    LiveProgress(item: item) { progress in
                        DownloadProgressRing(
                            systemName: item.isPaused ? "play.fill" : "pause.fill",
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
                .help(item.isPaused
                      ? Text("queue.resume.button", bundle: .module)
                      : Text("queue.pause.button", bundle: .module))
                .accessibilityLabel(item.isPaused
                                    ? Text("queue.resume.button", bundle: .module)
                                    : Text("queue.pause.button", bundle: .module))
            }
            // No inline trash — cancelling lives in the row's context menu,
            // matching the queue list (macOS right-click / iOS long-press).
        }
    }
}
