import SwiftUI

// MARK: - Shared tooltip chrome

/// The one long-hover presenter (600 ms dwell). QueueRowView keeps its own copy:
/// its `isHovering` also drives poster controls.
struct HoverTooltip<TooltipContent: View>: ViewModifier {
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
                    hoverTask = Task {
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
    func hoverTooltip<T: View>(enabled: Bool = true, @ViewBuilder _ tooltip: @escaping () -> T) -> some View {
        modifier(HoverTooltip(enabled: enabled, tooltip: tooltip))
    }
}

struct TooltipInfoLine: Identifiable {
    /// Doubles as the identity: labels are unique within one grid.
    let labelKey: String
    let value: String
    var valueColor: Color? = nil
    var mono: Bool = false

    var id: String { labelKey }
}

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

/// Ideal height forced: a height-squeezed column otherwise collapses the text to one truncated line.
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

/// Never truncated. Only the old file in a comparison drops to secondary.
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
