import SwiftUI

// MARK: - Shared tooltip chrome
//
// The container itself is `MediaTooltipChrome` (QueueItemPrimitives.swift) —
// every media tooltip renders inside it. This file owns the shared inner
// pieces: the info grid's label/value styling, the rating-pill row and the
// filename treatment, so tooltip surfaces can't drift apart visually again.
// (They did: filename colours, label styles and grid spacing all diverged
// before this was extracted.)

/// The ONE long-hover presenter: 600 ms dwell, then `tooltipPopover` on
/// the trailing edge. Every tooltip-bearing row/tile that doesn't need its
/// hover state for anything else goes through this — the dwell time and
/// dismiss behaviour can't drift per surface. (QueueRowView / group rows
/// keep their own copy: their `isHovering` also drives poster controls.)
struct HoverTooltip<TooltipContent: View>: ViewModifier {
    /// Skipped entirely when false (e.g. a tooltip with nothing to show).
    var enabled: Bool = true
    @ViewBuilder let tooltip: () -> TooltipContent
    @Environment(\.suppressRowTooltip) private var suppressRowTooltip
    #if os(macOS)
    @State private var isHovering = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onHover { hovering in
                isHovering = hovering
                hoverTask?.cancel()
                if hovering && enabled && !suppressRowTooltip {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        if !Task.isCancelled && isHovering { showTooltip = true }
                    }
                } else {
                    showTooltip = false
                }
            }
            .tooltipPopover(isPresented: $showTooltip, arrowEdge: .trailing) {
                tooltip()
            }
        #else
        content
        #endif
    }
}

extension View {
    /// See `HoverTooltip`.
    func hoverTooltip<T: View>(enabled: Bool = true, @ViewBuilder _ tooltip: @escaping () -> T) -> some View {
        modifier(HoverTooltip(enabled: enabled, tooltip: tooltip))
    }
}

/// One key–value line of a tooltip's info grid.
struct TooltipInfoLine: Identifiable {
    /// Catalog key of the label — doubles as the identity (labels are
    /// unique within one grid).
    let labelKey: String
    let value: String
    var valueColor: Color? = nil
    var mono: Bool = false

    var id: String { labelKey }
}

/// The tooltip's key–value grid — single source of the label column style
/// (11 pt secondary) and value style (11 pt primary, monospace opt-in).
struct TooltipInfoGrid: View {
    let lines: [TooltipInfoLine]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(lines) { line in
                GridRow(alignment: .firstTextBaseline) {
                    Text(LocalizedStringKey(line.labelKey), bundle: .module)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(verbatim: line.value)
                        .font(line.mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                        .foregroundStyle(line.valueColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Rating pills row — the same `RatingPill` chips the detail heroes render
/// (brand icons live ONLY in these pills, per the app's rating-icon rule).
struct TooltipRatingPills: View {
    let chips: [RatingChip]

    var body: some View {
        if !chips.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    RatingPill(chip: chip)
                }
            }
        }
    }
}

/// Synopsis block — sits DIRECTLY under the info grid in every tooltip
/// (before the custom-format strip and filename). One style: 11 pt
/// secondary, up to 8 lines, ideal height forced (see the fixedSize note
/// in MediaTooltipChrome's history: without it a height-squeezed column
/// collapses the text to one truncated line).
struct TooltipOverview: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(verbatim: text)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }
}

/// Filename, the one way it renders anywhere in the app: bare (no label),
/// 11 pt monospace, never truncated. Colour rule: a lone filename (and the
/// NEW side of a diff) is primary; only the OLD file in a comparison drops
/// to secondary.
struct TooltipFileName: View {
    let name: String?

    var body: some View {
        if let name, !name.isEmpty {
            Text(verbatim: name)
                .scaledFont(size: 11, design: .monospaced)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
