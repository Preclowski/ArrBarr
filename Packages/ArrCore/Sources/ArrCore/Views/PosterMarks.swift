import SwiftUI

// MARK: - Poster corner marks

/// Corner wedge for a title the media server says has been played.
struct WatchedCornerBadge: View {
    /// Default suits the library grid's 104–160pt tiles.
    var side: CGFloat = 26

    var body: some View {
        // The hairline keeps the fold's edge on busy art.
        Color.clear
            .frame(width: side, height: side)
            .glassEffect(.regular.tint(Color.accentColor.opacity(0.7)), in: Triangle())
            .overlay(Triangle().stroke(Color.white.opacity(0.35), lineWidth: 0.5))
            .accessibilityLabel(Text("library.watched.badge", bundle: .module))
            .help(Text("library.watched.badge", bundle: .module))
    }

    nonisolated private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.closeSubpath()
            return p
        }
    }
}

struct MonitorRibbon: View {
    var width: CGFloat = 10
    /// Surfaces that only draw a ribbon when monitored never pass `false`.
    var filled: Bool = true

    private var height: CGFloat { width * 1.6 }

    var body: some View {
        // Flat, no lift: a mark on the artwork. Solid white stays readable over any poster.
        Ribbon()
            .fill(Color.white.opacity(filled ? 1 : 0.35))
            .frame(width: width, height: height)
            .accessibilityLabel(Text(LocalizedStringKey(filled ? "common.monitored.button"
                                                              : "common.notMonitored.label"),
                                     bundle: .module))
    }

    nonisolated private struct Ribbon: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let notch = rect.height * 0.28
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - notch))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }
}

public extension View {
    /// Watched wedge (clipped to `cornerRadius`) with the monitored ribbon over it. `watched` honours the
    /// Settings toggle; `monitored` is `nil` where the flag is unknown, drawing no ribbon.
    func posterMarks(watched: Bool, monitored: Bool?, cornerRadius: CGFloat,
                     ribbonWidth: CGFloat = 10) -> some View {
        modifier(PosterMarks(watched: watched, monitored: monitored,
                             cornerRadius: cornerRadius, ribbonWidth: ribbonWidth))
    }
}

private struct PosterMarks: ViewModifier {
    let watched: Bool
    let monitored: Bool?
    let cornerRadius: CGFloat
    let ribbonWidth: CGFloat
    /// Not the environment object: tooltips and popovers don't inherit it, and a missing one crashes.
    @ObservedObject private var configStore = ConfigStore.shared

    func body(content: Content) -> some View {
        content
            // Only on a watched cover: an unconditional `clipShape` adds a render pass to every poster in a grid.
            .modifier(WatchedCorner(watched: watched && configStore.showWatchedIndicator,
                                    side: ribbonWidth * 1.6,
                                    cornerRadius: cornerRadius))
            .overlay(alignment: .topLeading) {
                if monitored == true {
                    MonitorRibbon(width: ribbonWidth)
                        .padding(.leading, ribbonWidth * 0.4)
                }
            }
    }
}

/// Conditional so untouched covers keep their plain compositing.
private struct WatchedCorner: ViewModifier {
    let watched: Bool
    let side: CGFloat
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if watched {
            content
                .overlay(alignment: .topTrailing) { WatchedCornerBadge(side: side) }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
        }
    }
}
