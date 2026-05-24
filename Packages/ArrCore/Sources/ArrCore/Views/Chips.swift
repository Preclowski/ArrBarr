import SwiftUI

// MARK: - Chip primitives
//
// Pulled out of QueueRowView.swift — these chrome bits are shared
// across queue rows, tooltips, detail views, and search results. One
// file makes the visual language easier to keep in sync.

/// Custom-format chips plus an optional score chip, wrapping with
/// `TooltipFlowLayout`. Used inside tooltips and detail surfaces;
/// for single-line strips with a fade-out, see `CustomFormatStrip`.
@ViewBuilder
public func customFormatChipStrip(tags: [String], score: Int?) -> some View {
    if !tags.isEmpty || (score ?? 0) != 0 {
        TooltipFlowLayout(spacing: 3) {
            ForEach(tags, id: \.self) { TagChip(text: $0) }
            if let score, score != 0 {
                let sign = score > 0 ? "+" : ""
                TagChip(text: "\(sign)\(score)", color: score > 0 ? .green : .red)
            }
        }
        .padding(.top, 2)
    }
}

/// A tag-style capsule with explicit colour-with-opacity background.
/// We avoid `.quaternary` (hierarchical material) because inside a
/// popover that container resolves to a much darker tone and the
/// chips render as solid black pills.
public struct TagChip: View {
    let text: String
    var color: Color

    public init(text: String, color: Color = .primary) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color == .primary ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

/// Wrapping layout for chip rows — flows children left-to-right and
/// wraps to the next line when the proposed width is exhausted.
/// Lighter than SwiftUI's `LazyVGrid` (no row-major alignment) which
/// is what you want for tag lists where each tag has its own width.
public struct TooltipFlowLayout: Layout {
    var spacing: CGFloat

    public init(spacing: CGFloat = 4) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(rows.count - 1) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [(indices: [Int], height: CGFloat)] {
        var rows: [(indices: [Int], height: CGFloat)] = []
        var current: (indices: [Int], height: CGFloat) = ([], 0)
        var x: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !current.indices.isEmpty && x + size.width > maxWidth {
                rows.append(current)
                current = ([], 0)
                x = 0
            }
            current.indices.append(i)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Single-line custom-format strip with a fade-out gradient when
/// chips overflow. Used by compact listing rows where wrapping would
/// blow up the row height. Detail surfaces use the wrapping
/// `customFormatChipStrip` instead.
public struct CustomFormatStrip: View {
    let formats: [String]
    let score: Int
    var help: String?
    /// Right-edge fade. Set `false` when the row already paints its
    /// own trailing gradient (e.g. the hover-action backdrop) —
    /// stacking two fades reads as a doubled gradient.
    var fadeTrailing: Bool

    public init(formats: [String], score: Int, help: String? = nil,
                fadeTrailing: Bool = true) {
        self.formats = formats
        self.score = score
        self.help = help
        self.fadeTrailing = fadeTrailing
    }

    public var body: some View {
        let strip = Color.clear
            .frame(height: 14)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                HStack(spacing: 4) {
                    ForEach(formats, id: \.self) { cf in
                        Text(cf)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    if score != 0 {
                        let sign = score > 0 ? "+" : ""
                        Text("\(sign)\(score)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(score > 0 ? Color.green : Color.red)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                .fixedSize()
            }
            .clipped()

        let view: AnyView = fadeTrailing
            ? AnyView(strip.mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            ))
            : AnyView(strip)

        if let help {
            view.help(Text(verbatim: help))
        } else {
            view
        }
    }
}
