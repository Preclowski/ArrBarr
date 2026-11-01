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

/// `TrailerRow`'s room: its header, the tiles and the two caption lines they always reserve.
struct SkeletonTrailerRow: View {
    private static let thumbnail = TrailerClip.thumbnailSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.quaternary).frame(width: 60, height: 12)
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
                            .fill(.quaternary).frame(width: Self.thumbnail.width, height: Self.thumbnail.height)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(.quaternary).frame(width: Self.thumbnail.width - 24, height: 9)
                            .frame(height: 28, alignment: .top)
                    }
                }
            }
            .padding(.vertical, 2)
            // The third tile runs off the margin, like the real row's.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .skeletonPulse()
    }
}

/// `SeasonSection`'s shape, under its real header: a series always has seasons.
struct SkeletonSeasonSection: View {
    var rows: Int = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailSectionHeader("detail.seasons.button")
            VStack(spacing: 2) {
                ForEach(0..<max(1, rows), id: \.self) { _ in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
                            .fill(.quaternary).frame(width: 40, height: 60)
                        VStack(alignment: .leading, spacing: 7) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(.quaternary).frame(width: 70, height: 11)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(.quaternary).frame(width: 130, height: 9)
                        }
                        .padding(.top, 2)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                }
            }
            .skeletonPulse()
        }
    }
}

private struct SkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            // Scoped to the opacity: `.animation(_:value:)` also caught layout landing in the same tick,
            // and the skeleton then bounced between its old and new position forever.
            // Reduce Motion: a steady dimmed placeholder instead of an endless pulse.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                $0.opacity(dim ? 0.5 : 1)
            }
            .onAppear { dim = true }
    }
}

extension View {
    func skeletonPulse() -> some View { modifier(SkeletonPulse()) }
}
