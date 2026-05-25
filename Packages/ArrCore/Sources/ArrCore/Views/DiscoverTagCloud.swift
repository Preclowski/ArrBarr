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
        public let icon: String    // SF Symbol name
        public let category: Category
        public init(id: TagID, label: String, icon: String, category: Category) {
            self.id = id
            self.label = label
            self.icon = icon
            self.category = category
        }
    }

    public enum Category {
        case genre, decade, rating, runtime
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
            HStack(spacing: 4) {
                Image(systemName: tag.icon)
                    .scaledFont(size: max(9, fontSize * 0.75), weight: .semibold)
                Text(LocalizedStringKey(tag.label), bundle: .module)
                    .scaledFont(size: fontSize, weight: .semibold)
            }
            .foregroundStyle(picked ? Color.white : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(picked ? tint : tint.opacity(0.18))
            )
            .shadow(color: picked ? tint.opacity(0.35) : .clear,
                    radius: 4, x: 0, y: 1)
            .scaleEffect(picked ? 1.06 : 1.0)
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
        // Filled pills feel larger at the same pt size → range dialled down one notch.
        let h = stableHash(tag.label)
        let bucket = Int(h % 5) // 0..4

        let center: CGFloat
        switch idx {
        case 0..<4:    center = 14   // was 16
        case 4..<10:   center = 12   // was 13
        default:       center = 11
        }
        let jitter: CGFloat = [-1, 0, 1, 0, 1][bucket]
        let s = center + jitter

        return s + (picked ? 1 : 0)
    }

    private func tagTint(for tag: Tag, idx: Int) -> Color {
        switch tag.category {
        case .genre:
            // Genres vary across the status palette — hash bucket → tint.
            let palette: [Color] = [.blue, .orange, .purple, .red, .green]
            return palette[Int(stableHash(tag.label) % UInt32(palette.count))]
        case .decade:
            return .blue
        case .rating:
            return .green     // "good" rating = .completed-green
        case .runtime:
            return .purple    // .importing-purple
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
