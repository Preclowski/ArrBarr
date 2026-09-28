import SwiftUI

/// 4-line overview whose "Show more" appears only when the text really clips, measured
/// with a hidden unclamped probe (a character-count threshold misfires both ways).
struct ExpandableOverview: View {
    let text: String
    @State private var expanded = false
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    /// +0.5 absorbs sub-pixel rounding in text layout.
    private var isTruncated: Bool { fullHeight > clampedHeight + 0.5 }

    /// Clipping one short line to show a button of the same height is a net loss. Derived from the
    /// measured 4-line height (÷4 = one line) so it tracks text scaling.
    private var hiddenOverflowIsWorthAButton: Bool {
        guard clampedHeight > 0 else { return true }
        let lineHeight = clampedHeight / 4
        return fullHeight - clampedHeight > lineHeight * 1.5
    }

    private var showsFullText: Bool {
        expanded || (isTruncated && !hiddenOverflowIsWorthAButton)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .scaledFont(size: 12)
                // `.secondary` blends into the glass behind it.
                .foregroundStyle(.primary)
                .lineLimit(showsFullText ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                // Measured on a hidden probe: the visible line limit depends on the result, so measuring
                // the visible text would feed back into itself and oscillate.
                .background(alignment: .topLeading) {
                    Text(text)
                        .scaledFont(size: 12)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: ClampedHeightKey.self,
                                    value: g.size.height
                                )
                            }
                        )
                }
                .background(alignment: .topLeading) {
                    // Unclamped copy at the same width; `opacity(0)` so SwiftUI still lays it out.
                    Text(text)
                        .scaledFont(size: 12)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: FullHeightKey.self,
                                    value: g.size.height
                                )
                            }
                        )
                }
                .onPreferenceChange(ClampedHeightKey.self) { clampedHeight = $0 }
                .onPreferenceChange(FullHeightKey.self) { fullHeight = $0 }
            if !expanded && isTruncated && hiddenOverflowIsWorthAButton {
                Button {
                    withAnimation(.smooth(duration: 0.18)) { expanded = true }
                } label: {
                    HStack(spacing: 3) {
                        Text("queue.showMore.button", bundle: .module)
                            .scaledFont(size: 11, weight: .medium)
                        Image(systemName: "chevron.down")
                            .scaledFont(size: 9, weight: .semibold)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ClampedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FullHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
