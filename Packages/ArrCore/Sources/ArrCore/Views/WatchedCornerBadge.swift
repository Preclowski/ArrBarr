import SwiftUI

/// Corner wedge marking a title the media server says has been played.
///
/// A folded corner rather than a floating badge: it reads at a glance across a
/// grid of covers, costs no artwork (it sits in the corner the poster's
/// composition never uses), and cannot be mistaken for the monitored bookmark
/// in the opposite corner.
struct WatchedCornerBadge: View {
    /// Leg length of the triangle. The default suits the library grid's
    /// 104–160pt tiles.
    var side: CGFloat = 26

    var body: some View {
        Triangle()
            .fill(Color.accentColor)
            .frame(width: side, height: side)
            .overlay(alignment: .topLeading) {
                Image(systemName: "checkmark")
                    .scaledFont(size: side * 0.34, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.leading, side * 0.14)
                    .padding(.top, side * 0.10)
            }
            .accessibilityLabel(Text("library.watched.badge", bundle: .module))
            .help(Text("library.watched.badge", bundle: .module))
    }

    /// Top-leading right triangle: the corner itself, then along the top and
    /// down the leading edge.
    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }
}
