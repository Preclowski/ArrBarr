import SwiftUI

// iMessage "invisible ink" style spoiler rendering for assistant chat
// messages. A message that contains `||spoiler||` markup is laid out as a
// wrapping flow of word tokens + spoiler chips; each spoiler chip blurs its
// text and shimmers a twinkling particle cloud over it until the bubble is
// tapped to reveal. The bubble owns the reveal state (tap anywhere toggles
// every spoiler), matching iMessage's per-message reveal.

// MARK: - Tokenisation

private enum SpoilerToken {
    case word(String)
    case ink(String)
}

private func words(_ s: Substring) -> [String] {
    s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
}

private func tokenize(_ raw: String) -> [SpoilerToken] {
    var tokens: [SpoilerToken] = []
    for segment in ChatSpoilerMarkup.parse(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
        switch segment {
        case .text(let s):
            // Word-level split so the flow wraps like prose. Inline markdown
            // is dropped on spoiler-bearing messages — an acceptable trade for
            // the per-span blur (plain assistant bubbles keep full markdown).
            for word in words(s[...]) { tokens.append(.word(word)) }
        case .spoiler(let s):
            // Spoilers are split into words too — otherwise a whole hidden
            // sentence is one un-wrappable token that blows the bubble out to
            // its full single-line width. Per-word ink wraps inline instead.
            for word in words(s[...]) { tokens.append(.ink(word)) }
        }
    }
    return tokens
}

// MARK: - Prose view

struct SpoilerProse: View {
    let text: String
    let revealed: Bool

    private var tokens: [SpoilerToken] { tokenize(text) }

    var body: some View {
        WrapFlowLayout(spacing: 3.5, lineSpacing: 3) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                tokenView(token)
            }
        }
    }

    @ViewBuilder
    private func tokenView(_ token: SpoilerToken) -> some View {
        switch token {
        case .word(let w):
            Text(w)
        case .ink(let s):
            SpoilerInk(text: s, revealed: revealed)
        }
    }
}

// MARK: - Single spoiler chip

private struct SpoilerInk: View {
    let text: String
    let revealed: Bool

    var body: some View {
        Text(text)
            .blur(radius: revealed ? 0 : 4.5)
            .opacity(revealed ? 1 : 0.92)
            // A hair of horizontal padding lets the soft blur of adjacent
            // hidden words bleed together into one continuous cloud-band
            // (no hard boxes — that read as "kwadratowy").
            .padding(.horizontal, 1.5)
            .overlay {
                if !revealed {
                    TwinkleCloud()
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: revealed)
            .accessibilityHidden(!revealed)
    }
}

// MARK: - Twinkling particle cloud

/// A field of softly blinking dots — the "ink cloud" hovering over hidden
/// text. Positions are deterministic (hashed per index) so it doesn't reflow
/// each frame; only opacity/size breathe over time.
private struct TwinkleCloud: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let count = max(10, Int((size.width * size.height) / 36))
                for i in 0..<count {
                    let fx = fract(sin(Double(i) * 12.9898) * 43758.5453)
                    let fy = fract(sin(Double(i) * 78.2330) * 24634.6345)
                    let x = fx * size.width
                    let y = fy * size.height
                    let phase = Double(i) * 1.7
                    let twinkle = 0.5 + 0.5 * sin(t * 3.0 + phase)
                    let alpha = 0.15 + 0.45 * twinkle
                    let d = 0.7 + 0.9 * twinkle
                    let rect = CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)
                    context.fill(Path(ellipseIn: rect), with: .color(.secondary.opacity(alpha)))
                }
            }
        }
    }
}

private func fract(_ x: Double) -> Double { x - floor(x) }

// MARK: - Tight wrapping layout

/// Like `TooltipFlowLayout` but reports the *tight* used width (max line
/// width) instead of claiming the full proposed width, so a short spoiler
/// message still produces a content-hugging bubble. Items are centred
/// vertically within their row so word baselines and the slightly taller
/// spoiler chips don't look ragged.
private struct WrapFlowLayout: Layout {
    var spacing: CGFloat = 3.5
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(rows.count - 1) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let yOffset = (row.height - size.height) / 2
                subviews[index].place(at: CGPoint(x: x, y: y + yOffset), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        var x: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !current.indices.isEmpty && x + size.width > maxWidth {
                current.width = x - spacing
                rows.append(current)
                current = ([], 0, 0)
                x = 0
            }
            current.indices.append(i)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty {
            current.width = x - spacing
            rows.append(current)
        }
        return rows
    }
}
