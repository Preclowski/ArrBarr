import SwiftUI

// MARK: - Poster corner marks
//
// Two marks sit on the top edge of every cover in the app: the monitored ribbon
// the arrs supply, tucked into the leading corner, and the watched wedge the
// media server supplies, folded into the trailing one. Opposite corners, so
// neither reads as a modifier of the other.

/// Corner wedge marking a title the media server says has been played.
///
/// A folded corner rather than a floating badge: it reads at a glance across a
/// grid of covers, costs no artwork (it sits in the corner the poster's
/// composition never uses), and carries no glyph of its own.
struct WatchedCornerBadge: View {
    /// Leg length of the triangle. The default suits the library grid's
    /// 104–160pt tiles.
    var side: CGFloat = 26

    var body: some View {
        Triangle()
            .fill(Color.accentColor)
            .frame(width: side, height: side)
            .accessibilityLabel(Text("library.watched.badge", bundle: .module))
            .help(Text("library.watched.badge", bundle: .module))
    }

    /// Top-trailing right triangle: the corner itself, then down the trailing
    /// edge and back along the top.
    private struct Triangle: Shape {
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

/// The monitored flag as a ribbon bookmark in the poster's top-leading corner:
/// a short strip flush with the artwork's top edge, notched at the bottom.
/// Replaces the `bookmark.fill` glyph that used to float in the opposite
/// corner.
struct MonitorRibbon: View {
    /// Everything scales off the ribbon's width, so one number resizes it for
    /// a 38pt list thumbnail or a 300pt detail hero.
    var width: CGFloat = 10
    /// Filled is monitored, hollow is not — the same on/off pairing the
    /// `bookmark.fill` / `bookmark` glyphs carried. Surfaces that only draw a
    /// ribbon when monitored never pass `false`.
    var filled: Bool = true

    private var height: CGFloat { width * 1.6 }

    var body: some View {
        // Flat, no lift: a mark ON the artwork, not an object floating over it.
        // Monitored is solid white — it has to be readable over any poster.
        // Unmonitored is the same white turned down, so the two read as one
        // mark at two strengths rather than as two different things.
        Ribbon()
            .fill(Color.white.opacity(filled ? 1 : 0.35))
            .frame(width: width, height: height)
            .accessibilityLabel(Text(LocalizedStringKey(filled ? "common.monitored.button"
                                                              : "common.notMonitored.label"),
                                     bundle: .module))
    }

    /// Rectangle with a V cut out of its bottom edge.
    private struct Ribbon: Shape {
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
    /// The shared corner treatment for any cover in the app: the watched wedge
    /// (clipped to the artwork's own radius) with the monitored ribbon over it.
    ///
    /// - Parameters:
    ///   - watched: the media server has played this title. Honours the
    ///     Settings toggle — call sites don't check it.
    ///   - monitored: the arr's monitored flag; `nil` on surfaces that don't
    ///     know it (a search result, a queue row), which draw no ribbon.
    ///   - cornerRadius: the artwork's radius, so the fold follows its corner.
    ///   - ribbonWidth: scales the ribbon to the cover it sits on.
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
    /// The shared store rather than the environment object: these marks are
    /// drawn inside tooltips and popovers, which do NOT inherit the host's
    /// environment, and a missing `@EnvironmentObject` is a crash rather than
    /// a default.
    @ObservedObject private var configStore = ConfigStore.shared

    func body(content: Content) -> some View {
        content
            // Overlay AND clip only on a watched cover: an unconditional
            // `clipShape` would put an extra render pass on every poster in a
            // grid for a corner most of them don't draw.
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

/// See `PosterMarks` — conditional so untouched covers keep their plain
/// compositing.
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
