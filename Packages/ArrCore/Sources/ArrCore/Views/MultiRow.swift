import SwiftUI

/// One row inside the multi-item list: status dot, episode/quality text,
/// and a thin progress bar. When `hoverDetail` is true and the item is an
/// upgrade, the row reveals existing-file detail on demand:
///   - macOS: hovering for ~350 ms opens a popover anchored to the row.
///   - iOS:   tapping the row toggles the same content inline below it.
struct MultiRow: View {
    let item: QueueItem
    let isFocused: Bool
    var showInlineUpgrade: Bool = true
    var showCustomFormats: Bool = false
    var hoverDetail: Bool = false
    /// Tap handler — drills the user into the episode detail
    /// overlay. Nil keeps the row passive.
    var onTap: (() -> Void)? = nil
    /// Per-item queue actions surfaced as a hover-only icon cluster
    /// on the trailing edge (same affordance pattern as queue list
    /// rows).
    var onPause: (() -> Void)? = nil
    var onResume: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var showHoverPopover = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var showDeleteConfirmation = false

    private var canPauseResume: Bool {
        item.status == .downloading || item.status == .paused
    }

    public var body: some View {
        Button {
            onTap?()
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        // Border on focus is gone — the user wanted the focused row
        // to read as part of the list, not stand out with a chrome
        // bar. Background tint stays (subtle hover/focus signal).
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
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
        // Bare-icon action cluster — unified across surfaces, see
        // `rowActionBackdrop` for the chip styling.
        .overlay(alignment: .trailing) {
            if isHovering, hasAnyAction {
                inlineActionIcons
                    .rowActionBackdrop()
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
        #endif
        .confirmationDialog(
            Text("Cancel this download?", bundle: .module),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) { onDelete?() } label: {
                Text("Cancel download", bundle: .module)
            }
            Button(role: .cancel) {} label: { Text("Keep download", bundle: .module) }
        } message: {
            Text(String(format: String(localized: "This will remove \"%@\" from the download client.", bundle: .module), item.title))
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.status.symbol)
                    .scaledFont(size: 9)
                    .foregroundStyle(item.status.tint)
                if let code = episodeCode {
                    Text(code)
                        .scaledFont(size: 11, weight: .semibold, monospacedDigit: true)
                        .foregroundStyle(.primary)
                }
                Text(headlineText)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.isUpgrade {
                    Image(systemName: "arrow.up.circle.fill")
                        .scaledFont(size: 9)
                        .foregroundStyle(.indigo)
                }
                Spacer(minLength: 4)
                if item.status == .queued {
                    Text(verbatim: trailingText)
                        .scaledFont(size: 10, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                }
                ScoreLabel(score: item.customFormatScore)
            }
            ThinProgressBar(progress: item.progress, tint: item.status.tint)
            if showCustomFormats, !item.customFormats.isEmpty {
                CustomFormatChips(formats: item.customFormats, score: 0)
                    .padding(.top, 1)
            }
            if !hoverDetail, showInlineUpgrade, isFocused, item.isUpgrade {
                Text(verbatim: upgradeHint)
                    .scaledFont(size: 10)
                    .foregroundStyle(.indigo)
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 6)
        .padding(.trailing, 4)
    }

    private var hasAnyAction: Bool {
        (canPauseResume && (onPause != nil || onResume != nil)) || onDelete != nil
    }

    #if os(macOS)
    @ViewBuilder
    private var inlineActionIcons: some View {
        HStack(spacing: 2) {
            if canPauseResume {
                if item.isPaused, let onResume {
                    IconButton(symbol: "play.fill", helpKey: "Resume",
                               accessibilityLabel: "Resume \(item.title)") { onResume() }
                } else if !item.isPaused, let onPause {
                    IconButton(symbol: "pause.fill", helpKey: "Pause",
                               accessibilityLabel: "Pause \(item.title)") { onPause() }
                }
            }
            if onDelete != nil {
                IconOverflowMenu(accessibilityLabel: "More actions") {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label(String(localized: "Cancel download", bundle: .module),
                              systemImage: "trash")
                    }
                }
            }
        }
    }
    #endif

    private var rowBackground: Color {
        if isFocused { return Color.accentColor.opacity(0.06) }
        if isHovering { return Color.primary.opacity(0.04) }
        return .clear
    }

    private var episodeCode: String? {
        guard let s = item.seasonNumber, let e = item.episodeNumber else { return nil }
        return String(format: "S%02dE%02d", s, e)
    }

    /// Episode title + quality, joined by a dot.
    private var headlineText: String {
        var bits: [String] = []
        if let t = item.episodeTitle, !t.isEmpty { bits.append(t) }
        if let q = item.quality, !q.isEmpty { bits.append(q) }
        if bits.isEmpty, let release = item.releaseName, !release.isEmpty { bits.append(release) }
        return bits.joined(separator: " · ")
    }

    private var trailingText: String {
        if item.status == .queued { return "Queued" }
        return "\(Int((item.progress * 100).rounded()))%"
    }

    private var upgradeHint: String {
        var bits: [String] = ["↑ replacing"]
        if let q = item.existingQuality, !q.isEmpty { bits.append(q) }
        if let s = item.existingCustomFormatScore, s != 0 {
            let sign = s > 0 ? "+" : ""
            bits.append("(\(sign)\(s))")
        }
        return bits.joined(separator: " ")
    }
}
