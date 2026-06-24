import SwiftUI

// MARK: - Loading skeletons
//
// Placeholder shapes shown while a section's data is still loading, so a
// detail surface fills in element-by-element instead of gating the whole
// view behind one centred spinner. A gentle opacity pulse reads as
// "loading" (a static grey bar reads as "broken"). Sizes roughly match the
// real content so nothing jumps when the data lands.

/// A single rounded placeholder bar. `width: nil` fills the available width.
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

/// Paragraph placeholder — `count` full-width lines, the last one short, so
/// it reads as a block of prose (overview).
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

/// Stack of full-width row placeholders — for season / track / episode lists.
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

/// Horizontal cast-strip placeholder — circular headshot + name bar per slot.
/// Pulses as one unit (raw shapes, not `SkeletonBar`, to avoid stacking the
/// pulse modifier twice).
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
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

extension View {
    /// Gentle opacity pulse marking a placeholder as actively loading.
    func skeletonPulse() -> some View { modifier(SkeletonPulse()) }
}
