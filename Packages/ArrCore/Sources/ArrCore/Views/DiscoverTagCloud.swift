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
        .frame(minHeight: 320)
    }

    // MARK: - Pill builder

    @ViewBuilder
    private func pill(_ tag: Tag, idx: Int, t: TimeInterval, size: CGSize) -> some View {
        let picked = isPicked(tag.id)
        let base = basePosition(for: tag, idx: idx, in: size)
        let bob = oscillation(idx: idx, t: t)

        // Base rotation derived from the label hash → persistent across
        // re-renders. Range ±12° feels lively without becoming hard to read.
        let baseAngleDeg = Double(stableHash(tag.label) % 25) - 12  // -12..+12
        // TimelineView wobble adds ±2° on top, with per-tag phase.
        let wobbleDeg = sin(t * 0.5 + Double(idx) * 0.7) * 2
        let rot = Angle(degrees: baseAngleDeg + wobbleDeg)

        let fontSize = fontSize(for: tag, idx: idx, picked: picked)
        let tint = tagTint(for: tag, idx: idx)

        Button {
            onToggle(tag.id)
        } label: {
            Text(LocalizedStringKey(tag.label), bundle: .module)
                .scaledFont(size: fontSize, weight: picked ? .semibold : .medium)
                .padding(.horizontal, picked ? 12 : 10)
                .padding(.vertical, picked ? 6 : 5)
                .background(
                    Capsule().fill(picked
                        ? tint.opacity(0.25)
                        : tint.opacity(0.08))
                )
                .overlay(
                    Capsule().stroke(picked ? tint.opacity(0.7) : .clear,
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

    /// Phyllotactic (golden-angle) spiral placement. Each tag radiates from
    /// center at an irrational angle increment — produces natural-looking
    /// circular distribution with no obvious pattern.
    private func basePosition(for tag: Tag, idx: Int, in size: CGSize) -> CGPoint {
        let cx = size.width / 2
        let cy = size.height / 2

        // r grows as sqrt(idx) so density stays roughly uniform.
        // 28 was tuned for ~21 tags in a ~376×320 area.
        let r = sqrt(Double(idx) + 0.5) * 28

        // Golden angle in radians (≈ 137.508°). Irrational ratio → no
        // regular spokes appear.
        let goldenAngle = Double.pi * (3.0 - sqrt(5.0))
        let theta = Double(idx) * goldenAngle

        // Per-tag micro-jitter from label hash — adjacent indices won't sit
        // perfectly on the spiral.
        let h = stableHash(tag.label)
        let jr = Double((h & 0xFF)) / 255.0 - 0.5       // -0.5 ... +0.5
        let jt = Double(((h >> 8) & 0xFF)) / 255.0 - 0.5

        let x = cx + CGFloat((r + jr * 8) * cos(theta + jt * 0.25))
        let y = cy + CGFloat((r + jr * 8) * sin(theta + jt * 0.25))

        // Clamp to interior so wider pills near the edge don't clip off.
        let pad: CGFloat = 50
        return CGPoint(
            x: min(max(x, pad), size.width - pad),
            y: min(max(y, pad * 0.6), size.height - pad * 0.6)
        )
    }

    private func oscillation(idx: Int, t: TimeInterval) -> CGVector {
        let phase = Double(idx) * 0.9
        return CGVector(
            dx: CGFloat(sin(t * 0.6 + phase) * 2.5),
            dy: CGFloat(cos(t * 0.5 + phase * 1.3) * 3.0)
        )
    }

    private func fontSize(for tag: Tag, idx: Int, picked: Bool) -> CGFloat {
        // First few tags (center) are visually heavier; hash variance
        // prevents every Nth tag reading as the same size.
        let h = stableHash(tag.label)
        let bucket = Int(h % 5) // 0..4

        let center: CGFloat
        switch idx {
        case 0..<4:    center = 16
        case 4..<10:   center = 13
        default:       center = 11
        }
        let jitter: CGFloat = [-1, 0, 1, 0, 2][bucket]
        let s = center + jitter

        return s + (picked ? 1 : 0)
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
