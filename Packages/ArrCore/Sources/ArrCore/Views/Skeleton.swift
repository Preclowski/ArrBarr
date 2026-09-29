import SwiftUI

// MARK: - Loading skeletons
// The pulse reads as loading where a static grey bar reads as broken.

/// `width: nil` fills the available width.
struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 11
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quaternary)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .skeletonPulse()
    }
}

struct SkeletonLines: View {
    var count: Int = 3
    var lineHeight: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<max(1, count), id: \.self) { i in
                SkeletonBar(width: i == count - 1 ? 110 : nil, height: lineHeight)
            }
        }
    }
}

struct SkeletonRows: View {
    var count: Int = 4
    var rowHeight: CGFloat = 30
    var spacing: CGFloat = 4

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<max(1, count), id: \.self) { _ in
                SkeletonBar(height: rowHeight, cornerRadius: Tokens.Radius.chip)
            }
        }
    }
}

/// Raw shapes, not `SkeletonBar`, so the pulse modifier isn't stacked twice.
struct SkeletonCastRow: View {
    var count: Int = 6

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<max(1, count), id: \.self) { _ in
                VStack(spacing: 4) {
                    Circle().fill(.quaternary).frame(width: 46, height: 46)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.quaternary).frame(width: 42, height: 7)
                }
            }
        }
        .skeletonPulse()
    }
}

private struct SkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            // Reduce Motion: a steady dimmed placeholder instead of an endless pulse.
            .onAppear { dim = true }
            .transaction { if reduceMotion { $0.animation = nil } }
    }
}

extension View {
    func skeletonPulse() -> some View { modifier(SkeletonPulse()) }
}
