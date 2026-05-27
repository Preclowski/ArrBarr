import SwiftUI

/// Flow-layout container — lays children left-to-right, wrapping to a
/// new row when the next child would overflow. Used by the picker pill
/// cloud and the card's genre label wrap.
struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let (_, totalHeight) = layoutRows(maxWidth: maxWidth, subviews: subviews)
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (rows, _) = layoutRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            for idx in row {
                let s = subviews[idx].sizeThatFits(.unspecified)
                subviews[idx].place(at: CGPoint(x: x, y: y),
                                    proposal: ProposedViewSize(width: s.width, height: s.height))
                x += s.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func layoutRows(maxWidth: CGFloat, subviews: Subviews) -> (rows: [[Int]], totalHeight: CGFloat) {
        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let s = sub.sizeThatFits(.unspecified)
            let needed = s.width + (rows[rows.count - 1].isEmpty ? 0 : spacing)
            if rowWidth + needed > maxWidth, !rows[rows.count - 1].isEmpty {
                totalHeight += currentRowHeight + spacing
                rows.append([])
                rowWidth = 0
                currentRowHeight = 0
            }
            rows[rows.count - 1].append(i)
            rowWidth += s.width + (rows[rows.count - 1].count > 1 ? spacing : 0)
            currentRowHeight = max(currentRowHeight, s.height)
        }
        totalHeight += currentRowHeight
        return (rows, totalHeight)
    }
}
