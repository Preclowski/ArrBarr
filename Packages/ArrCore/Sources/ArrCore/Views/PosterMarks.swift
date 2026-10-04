import SwiftUI

// MARK: - Poster corner marks

/// Corner wedge for a title the media server says has been played.
struct WatchedCornerBadge: View {
    /// Default suits the library grid's 104–160pt tiles.
    var side: CGFloat = 26
    /// A solid tint instead of glass, for covers drawn inside the Roulette's shaders, where glass has no
    /// backdrop to refract and would cost a pass per poster per frame.
    var flat = false

    var body: some View {
        // The hairline keeps the fold's edge on busy art.
        wedge
            .frame(width: side, height: side)
            .overlay(Triangle().stroke(Color.white.opacity(0.35), lineWidth: 0.5))
            .accessibilityLabel(Text("library.watched.badge", bundle: .module))
            .help(Text("library.watched.badge", bundle: .module))
    }

    @ViewBuilder
    private var wedge: some View {
        if flat {
            Triangle().fill(Color.accentColor.opacity(0.85))
        } else {
            Color.clear.glassEffect(.regular.tint(Color.accentColor.opacity(0.7)), in: Triangle())
        }
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
    /// Hover on a toggle: the ribbon drops a little and previews the state a click sets.
    var hovering: Bool = false

    private var height: CGFloat { width * (hovering ? 2 : 1.6) }
    private var fillOpacity: Double {
        guard hovering else { return filled ? 1 : 0.35 }
        return filled ? 0.6 : 0.8
    }

    var body: some View {
        // Flat, no lift: a mark on the artwork. Solid white stays readable over any poster.
        Ribbon()
            .fill(Color.white.opacity(fillOpacity))
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

extension View {
    /// Watched wedge (clipped to `cornerRadius`), the monitored ribbon over it and the library strip along the
    /// bottom. `watched` honours the Settings toggle; a `nil` `monitored` or `library` draws nothing.
    func posterMarks(watched: Bool = false, monitored: Bool? = nil, library: LibraryMark? = nil,
                     cornerRadius: CGFloat, ribbonWidth: CGFloat = 10) -> some View {
        modifier(PosterMarks(watched: watched, monitored: monitored, library: library,
                             cornerRadius: cornerRadius, ribbonWidth: ribbonWidth))
    }
}

private struct PosterMarks: ViewModifier {
    let watched: Bool
    let monitored: Bool?
    let library: LibraryMark?
    let cornerRadius: CGFloat
    let ribbonWidth: CGFloat
    /// Not the environment object: tooltips and popovers don't inherit it, and a missing one crashes.
    private var configStore: ConfigStore { .shared }

    func body(content: Content) -> some View {
        content
            // Only on a watched cover: an unconditional `clipShape` adds a render pass to every poster in a grid.
            .modifier(WatchedCorner(watched: watched && configStore.showWatchedIndicator,
                                    side: ribbonWidth * 1.6,
                                    cornerRadius: cornerRadius))
            .overlay {
                if let library {
                    LibraryMarkEdge(mark: library, thickness: ribbonWidth < 10 ? 1.5 : 3, cornerRadius: cornerRadius)
                }
            }
            .overlay(alignment: .topLeading) {
                if monitored == true {
                    MonitorRibbon(width: ribbonWidth)
                        .padding(.leading, ribbonWidth * 0.4)
                }
            }
    }
}

// MARK: - Library mark

/// Where a title stands in the arr: blue once added, green once on disk.
enum LibraryMark {
    case inLibrary, downloaded

    init(downloaded: Bool) { self = downloaded ? .downloaded : .inLibrary }

    fileprivate var label: LocalizedStringKey { self == .downloaded ? "Downloaded" : "library.mark.inLibrary" }

    /// The platform colour, not SwiftUI's `.green`/`.blue`: the menu-bar panel blends those with what's under them,
    /// washing the strip out on light artwork.
    private var color: Color {
        #if os(macOS)
        Color(nsColor: self == .downloaded ? .systemGreen : .systemBlue)
        #else
        Color(uiColor: self == .downloaded ? .systemGreen : .systemBlue)
        #endif
    }

    /// Glass like the watched wedge: its rim parts the strip from light artwork, where a flat green or blue fades.
    /// `flat` for the Roulette's hero strip, where glass over the stage read as a faint wash.
    @ViewBuilder
    func strip(in shape: some Shape, flat: Bool = false) -> some View {
        if flat {
            shape.fill(color)
        } else {
            Color.clear.glassEffect(.regular.tint(color.opacity(0.7)), in: shape)
        }
    }
}

extension LibraryEntry {
    /// A Roulette entry from TMDB carries `arrId` 0 when the arr doesn't have it.
    var libraryMark: LibraryMark? { arrId == 0 ? nil : LibraryMark(downloaded: state == .complete) }
}

/// A strip along the poster's bottom edge.
private struct LibraryMarkEdge: View {
    let mark: LibraryMark
    let thickness: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        mark.strip(in: PosterBottomEdge(thickness: thickness, cornerRadius: cornerRadius))
            .overlay(alignment: .bottom) {
                // The edge itself is too thin to aim the tooltip at.
                Color.clear
                    .frame(height: thickness * 4)
                    .contentShape(Rectangle())
                    .help(Text(mark.label, bundle: .module))
            }
            .accessibilityElement()
            .accessibilityLabel(Text(mark.label, bundle: .module))
    }
}

/// Cut from the poster's own rounded rect, so the ends follow its corners without a clip pass.
nonisolated struct PosterBottomEdge: Shape {
    let thickness: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let strip = Path(CGRect(x: rect.minX, y: rect.maxY - thickness, width: rect.width, height: thickness))
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect).intersection(strip)
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
