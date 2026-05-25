import SwiftUI

/// Animated tag cloud view — Siri-style floating pills with varying font
/// sizes, accent colors, gentle oscillation, and click-to-toggle.
///
/// Each pill is positioned via `.position(_:)` so SwiftUI hit-testing
/// works at the animated location (not the layout origin). Positions are
/// derived deterministically from a hash of each tag's label so the cloud
/// looks identical on every render.
public struct DiscoverTagCloud<TagID: Hashable & Sendable>: View {
    let tags: [Tag]
    let isPicked: (TagID) -> Bool
    let onToggle: (TagID) -> Void

    // MARK: - Tag descriptor

    public struct Tag: Identifiable {
        public let id: TagID
        public let label: String   // also used as LocalizedStringKey
        public let palette: Palette
        public init(id: TagID, label: String, palette: Palette) {
            self.id = id
            self.label = label
            self.palette = palette
        }
    }

    public enum Palette {
        /// Colorful — cycles through purple / teal / orange / blue / pink.
        case mood
        /// Muted — grey fill, narrower size range, feels categorical.
        case genre
    }

    // MARK: - Init

    public init(tags: [Tag],
                isPicked: @escaping (TagID) -> Bool,
                onToggle: @escaping (TagID) -> Void) {
        self.tags = tags
        self.isPicked = isPicked
        self.onToggle = onToggle
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(Array(tags.enumerated()), id: \.element.id) { idx, tag in
                        pill(tag, idx: idx, t: t, size: geo.size)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .frame(minHeight: 280)
    }

    // MARK: - Pill builder

    @ViewBuilder
    private func pill(_ tag: Tag, idx: Int, t: TimeInterval, size: CGSize) -> some View {
        let picked = isPicked(tag.id)
        let base = basePosition(for: tag, idx: idx, in: size)
        let bob = oscillation(idx: idx, t: t)
        let rot = Angle(degrees: sin(t * 0.5 + Double(idx) * 0.7) * 3)
        let fs = fontSize(for: tag, idx: idx, picked: picked)
        let tint = tagTint(for: tag, idx: idx)

        Button {
            onToggle(tag.id)
        } label: {
            Text(LocalizedStringKey(tag.label), bundle: .module)
                .scaledFont(size: fs, weight: picked ? .semibold : .medium)
                .padding(.horizontal, picked ? 12 : 10)
                .padding(.vertical, picked ? 6 : 5)
                .background(
                    Capsule().fill(picked
                        ? tint.opacity(0.25)
                        : tint.opacity(0.08))
                )
                .overlay(
                    Capsule().stroke(
                        picked ? tint.opacity(0.7) : .clear,
                        lineWidth: picked ? 1 : 0)
                )
                .foregroundStyle(picked ? tint : .primary.opacity(0.85))
                .scaleEffect(picked ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .rotationEffect(rot)
        .position(x: base.x + bob.dx, y: base.y + bob.dy)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: picked)
    }

    // MARK: - Layout helpers

    /// Stable, hash-derived base position. Uses a loose 4-column grid with
    /// per-tag jitter so the layout doesn't read as a grid.
    private func basePosition(for tag: Tag, idx: Int, in size: CGSize) -> CGPoint {
        let cols = 4
        let rows = max(3, (tags.count + cols - 1) / cols)
        let col = idx % cols
        let row = idx / cols
        let cellW = size.width / CGFloat(cols)
        let cellH = size.height / CGFloat(rows)
        let baseX = cellW * (CGFloat(col) + 0.5)
        let baseY = cellH * (CGFloat(row) + 0.5)
        // Per-tag jitter from label hash so the grid baseline isn't obvious.
        let h = stableHash(tag.label)
        let jitterX = CGFloat((h & 0xFF)) / 255.0 - 0.5         // -0.5 ... +0.5
        let jitterY = CGFloat(((h >> 8) & 0xFF)) / 255.0 - 0.5
        return CGPoint(
            x: (baseX + jitterX * cellW * 0.35).clamped(to: 40...(size.width - 40)),
            y: (baseY + jitterY * cellH * 0.35).clamped(to: 16...(size.height - 16))
        )
    }

    private func oscillation(idx: Int, t: TimeInterval) -> CGVector {
        let phase = Double(idx) * 0.9
        return CGVector(
            dx: CGFloat(sin(t * 0.6 + phase) * 4),
            dy: CGFloat(cos(t * 0.5 + phase * 1.3) * 5)
        )
    }

    private func fontSize(for tag: Tag, idx: Int, picked: Bool) -> CGFloat {
        let h = stableHash(tag.label)
        let bucket = Int(h % 4) // 0..3
        let base: CGFloat
        switch tag.palette {
        case .mood:
            base = [11, 12, 13, 14][bucket]
        case .genre:
            base = [11, 11, 12, 13][bucket]
        }
        return base + (picked ? 1 : 0)
    }

    private func tagTint(for tag: Tag, idx: Int) -> Color {
        switch tag.palette {
        case .mood:
            let palette: [Color] = [.purple, .orange, .teal, .blue, .pink]
            return palette[Int(stableHash(tag.label) % UInt32(palette.count))]
        case .genre:
            return .gray
        }
    }

    // MARK: - FNV-1a hash

    /// Deterministic across runs — no Hasher seed surprises. The cloud
    /// looks identical every time the user opens Discover.
    private func stableHash(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for byte in s.utf8 {
            h ^= UInt32(byte)
            h = h &* 16777619
        }
        return h
    }
}

// MARK: - Comparable clamp helper

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
