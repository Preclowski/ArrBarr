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

/// "queued" pill — sits on rows that are actively downloading or
/// queued for download. Outline (stroke + clear fill) so it reads
/// as a quieter status tag than the filled chips elsewhere on the
/// row. Orange tint matches in-flight semantics used in the rest
/// of the app for paused / processing states.
public struct InQueueBadge: View {
    public init() {}

    public var body: some View {
        Text("Queued", bundle: .module)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.lowercase)
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .stroke(Color.orange.opacity(0.55), lineWidth: 1)
            )
    }
}

/// Source identity chip — capsule with the arr's SF Symbol plus its
/// display name ("Radarr" / "Sonarr" / "Lidarr" / "Whisparr"). Used
/// as the title-slot badge inside the queue-search status-grouped
/// layout, replacing `InLibraryBadge` / `NewBadge` whose meaning is
/// now encoded by the section header. The arr's name is spelled out
/// (not just the glyph) so the chip carries the same identity the
/// per-arr section headers use elsewhere in the app.
public struct SourceGlyphChip: View {
    let source: QueueItem.Source
    public init(source: QueueItem.Source) {
        self.source = source
    }
    public var body: some View {
        HStack(spacing: 3) {
            ServiceIcon(source: source, size: 9)
            Text(verbatim: source.displayName)
                .scaledFont(size: 9, weight: .semibold)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
    }
}

/// "library" pill rendered next to titles whenever the item is
/// already on the user's arr. Outline-only — quieter than the
/// solid-fill genre / rating chips so the badge reads as a status
/// tag, not a content tag. Accent-tinted to match the chevron
/// drill-in affordance these rows already use.
public struct InLibraryBadge: View {
    public init() {}

    public var body: some View {
        Text("Library", bundle: .module)
            .scaledFont(size: 9, weight: .semibold)
            .textCase(.lowercase)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
            )
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
        // Stroke mirrors the text tint — neutral chips keep the
        // primary outline, but the green/red diff chips and the
        // ±score chip need the border to read in the same colour
        // family or the row stops feeling like a colour-coded diff.
        let strokeColor: Color = (color == .primary) ? .primary : color
        Text(text)
            .scaledFont(size: 9, weight: .medium)
            .foregroundStyle(color == .primary ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chip).stroke(strokeColor.opacity(0.30), lineWidth: 0.75))
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
                            .scaledFont(size: 9, weight: .medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chip).stroke(Color.primary.opacity(0.22), lineWidth: 0.75))
                    }
                    if score != 0 {
                        let sign = score > 0 ? "+" : ""
                        let scoreColor: Color = score > 0 ? .green : .red
                        Text(verbatim: "\(sign)\(score)")
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(scoreColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chip).stroke(scoreColor.opacity(0.30), lineWidth: 0.75))
                    }
                }
                .fixedSize()
            }
            .clipped()

        // Always mask with a gradient; when not fading, the stops are solid
        // black end-to-end (a no-op mask). Keeps one concrete view type, so no
        // AnyView erasure is needed for the ternary.
        let view = strip.mask(
            LinearGradient(
                stops: fadeTrailing
                    ? [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1.0),
                    ]
                    : [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 1.0),
                    ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )

        if let help {
            view.help(Text(verbatim: help))
        } else {
            view
        }
    }
}
