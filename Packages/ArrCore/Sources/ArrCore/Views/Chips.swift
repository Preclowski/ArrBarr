import SwiftUI

// MARK: - Chip primitives

@ViewBuilder
func customFormatChipStrip(tags: [String], score: Int?) -> some View {
    if !tags.isEmpty || (score ?? 0) != 0 {
        TooltipFlowLayout(spacing: 3) {
            ForEach(tags, id: \.self) { TagChip(text: $0) }
            if let score, score != 0 {
                // Chip metrics, no stroke — aligns with the TagChips without
                // reading as one more custom format.
                ScoreChip(score: score)
            }
        }
        .padding(.top, 2)
    }
}

/// Outlined so it reads as a quieter status tag than the filled chips.
struct InQueueBadge: View {
    init() {}

    var body: some View {
        Text("queue.queued.button", bundle: .module)
            .scaledFont(size: 9, weight: .semibold)
            .textCase(.lowercase)
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .stroke(Color.orange.opacity(0.55), lineWidth: 0.75)
            )
    }
}

struct SourceGlyphChip: View {
    let source: QueueItem.Source
    init(source: QueueItem.Source) {
        self.source = source
    }
    var body: some View {
        HStack(spacing: 3) {
            ServiceIcon(source: source, size: 9)
            Text(verbatim: source.displayName)
                .scaledFont(size: 9, weight: .semibold)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .filledChipBackground()
    }
}

public extension LibraryEntry.FileState {
    /// Matches the arr web UIs' state colours; unmonitored stays untinted (its surface is already dimmed).
    var chipColor: Color? {
        switch self {
        case .complete: return .green
        case .partial: return .orange
        case .missing: return .red
        // Radarr paints not-yet-available blue — nothing is wrong, there's
        // just nothing to grab yet.
        case .notAvailable: return .blue
        case .unmonitored: return nil
        }
    }

    func statusText(have: Int?, total: Int?, locale: Locale) -> String {
        switch self {
        case .complete:
            return AppLocalized.string("Downloaded", locale: locale)
        case .partial:
            return "\(have ?? 0)/\(total ?? 0)"
        case .missing:
            if let total, total > 0 { return "\(have ?? 0)/\(total)" }
            return AppLocalized.string("search.missing.button", locale: locale)
        case .notAvailable:
            return AppLocalized.string("library.status.notAvailable", locale: locale)
        case .unmonitored:
            return AppLocalized.string("Unmonitored", locale: locale)
        }
    }
}

/// One mapping, so "Downloaded" is the same word and green on library rows and detail heroes alike.
struct MediaStateChip: View {
    let state: LibraryEntry.FileState
    /// Only rendered for the counted states.
    var have: Int? = nil
    var total: Int? = nil
    let locale: Locale

    init(state: LibraryEntry.FileState, have: Int? = nil, total: Int? = nil, locale: Locale) {
        self.state = state
        self.have = have
        self.total = total
        self.locale = locale
    }

    var body: some View {
        StateChip(
            text: state.statusText(have: have, total: total, locale: locale),
            color: state.chipColor ?? .gray
        )
    }
}

/// "Downloaded" when on disk, "library" when on the arr but not downloaded — never both.
struct LibraryStateBadge: View {
    let isDownloaded: Bool

    @Environment(\.locale) private var locale

    init(isDownloaded: Bool) {
        self.isDownloaded = isDownloaded
    }

    var body: some View {
        if isDownloaded {
            MediaStateChip(state: .complete, locale: locale)
        } else {
            InLibraryBadge()
        }
    }
}

struct InLibraryBadge: View {
    init() {}

    var body: some View {
        Text("search.library.button", bundle: .module)
            .scaledFont(size: 9, weight: .semibold)
            .textCase(.lowercase)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .stroke(Color.accentColor.opacity(0.55), lineWidth: 0.75)
            )
    }
}

/// Same metrics as a chip so it baseline-aligns with the TagChips beside it.
struct ScoreChip: View {
    let score: Int

    init(score: Int) {
        self.score = score
    }

    var body: some View {
        ScoreLabel(score: score, size: 9, weight: .semibold)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .chipOutline(ScoreLabel.color(score))
    }
}

/// Filled and untinted: it earns distinction from the fill, not a hue that would read as an alert.
struct ProfileChip: View {
    let name: String

    init(name: String) {
        self.name = name
    }

    var body: some View {
        Text(verbatim: name)
            .scaledFont(size: 9, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .filledChipBackground()
    }
}

extension View {
    /// A tinted chip is outlined in its own tint, never a neutral grey.
    func chipOutline(_ color: Color, opacity: Double = 0.30) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                .stroke(color.opacity(opacity), lineWidth: 0.75)
        )
    }

    /// For a chip that is a link: the outline steps away from what it looks like on screen under the pointer,
    /// darker when it reads light, lighter when it reads dark. `inset` strokes inside the shape.
    func hoverChipOutline<S: InsettableShape>(_ color: Color, opacity: Double, shape: S,
                                              inset: Bool = false) -> some View {
        modifier(HoverChipOutline(color: color, opacity: opacity, shape: shape, inset: inset))
    }

    /// Outlined chips centre a 0.75 pt stroke on their edge, so the fill grows by half of it to match size.
    func filledChipBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                .fill(Color.primary.opacity(0.08))
                .padding(-0.375)
        )
    }
}

private struct HoverChipOutline<S: InsettableShape>: ViewModifier {
    let color: Color
    let opacity: Double
    let shape: S
    let inset: Bool
    @State private var hovering = false
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        let stroke = hovering ? hoverColor : color.opacity(opacity)
        content
            .overlay {
                if inset {
                    shape.strokeBorder(stroke, lineWidth: 0.75)
                } else {
                    shape.stroke(stroke, lineWidth: 0.75)
                }
            }
            .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
    }

    /// Judged as composited over the panel, so a faint outline in dark mode counts as dark.
    private var hoverColor: Color {
        let c = color.resolve(in: environment)
        let backdrop: Float = environment.colorScheme == .dark ? 0.12 : 0.96
        let a = Float(opacity)
        func over(_ v: Float) -> Float { v * a + backdrop * (1 - a) }
        let luminance = 0.2126 * over(c.red) + 0.7152 * over(c.green) + 0.0722 * over(c.blue)
        return color.mix(with: luminance > 0.5 ? .black : .white, by: 0.35).opacity(0.8)
    }
}

struct StateChip: View {
    let text: String
    var color: Color = .gray

    init(text: String, color: Color = .gray) {
        self.text = text
        self.color = color
    }

    var body: some View {
        // Tonal: a faint wash of the colour under text in the colour, so a status stands apart from the outlined
        // tags without shouting. The fill grows by half the outlined chips' stroke to keep their size.
        Text(verbatim: text)
            .scaledFont(size: 9, weight: .medium)
            .foregroundStyle(color.tonalText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .fill(color.panelSafe.opacity(0.22))
                    .padding(-0.375)
            )
    }
}

/// A title's release status. A series shows only "Ended": "continuing" says nothing on a show you'd add.
struct ReleaseStatusChip: View {
    let status: String?
    let source: QueueItem.Source
    @Environment(\.locale) private var locale

    var body: some View {
        if source == .sonarr {
            if status?.lowercased() == "ended", let text = ArrReleaseStatusLabel.text("ended", locale: locale) {
                // Brown: a fact, not a problem; green/orange/red/blue are file states, indigo is upgrade.
                StateChip(text: text, color: .brown)
            }
        } else if let text = ArrReleaseStatusLabel.text(status, locale: locale) {
            StateChip(text: text)
        }
    }
}

extension Color {
    /// Through the platform colour: the menu-bar panel washes SwiftUI's own colours out over light content.
    var panelSafe: Color {
        #if os(macOS)
        Color(nsColor: NSColor(self))
        #else
        self
        #endif
    }

    /// Text over a wash of this colour: a touch lighter on dark surfaces, darker on light ones, where the bright
    /// system greens and oranges would not read.
    var tonalText: Color {
        #if os(macOS)
        nonisolated(unsafe) let base = NSColor(self)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var shade = base
            appearance.performAsCurrentDrawingAppearance {
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                shade = base.usingColorSpace(.sRGB)?.blended(withFraction: dark ? 0.1 : 0.35,
                                                             of: dark ? .white : .black) ?? base
            }
            return shade
        })
        #else
        nonisolated(unsafe) let base = UIColor(self)
        return Color(uiColor: UIColor { traits in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            let (target, f): (CGFloat, CGFloat) = traits.userInterfaceStyle == .dark ? (1, 0.1) : (0, 0.35)
            return UIColor(red: r + (target - r) * f, green: g + (target - g) * f, blue: b + (target - b) * f, alpha: a)
        })
        #endif
    }
}

/// Explicit colour background: `.quaternary` resolves near-black inside a popover.
struct TagChip: View {
    let text: String
    var color: Color

    init(text: String, color: Color = .primary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        let strokeColor: Color = (color == .primary) ? .primary : color
        Text(text)
            .scaledFont(size: 9, weight: .medium)
            // `Color.primary`, not the hierarchical `.primary` style, which dims inside secondary blocks.
            .foregroundStyle(color == .primary ? Color.primary : color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .chipOutline(strokeColor, opacity: 0.40)
    }
}

struct TooltipFlowLayout: Layout {
    var spacing: CGFloat

    init(spacing: CGFloat = 4) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(rows.count - 1) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
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

