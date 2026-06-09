import SwiftUI

/// 4-line overview block with a "Show more" disclosure that ONLY
/// appears when the text actually got truncated. The previous
/// implementation gated the button on `text.count > 220`, which:
///
///   - false-positive: text with lots of newlines / short lines
///     fit in 4 lines at >220 chars → button appeared, tapping
///     "expanded" the same content (visual no-op);
///   - false-negative: narrow popover width + long words → text
///     wrapped to a 5th line at <220 chars → button missing.
///
/// Replaced with a SwiftUI height-comparison probe: render a hidden
/// copy of the same text at the same width without `lineLimit`,
/// measure its height, and compare against the visible-4-line
/// height. If they disagree, the visible text is clipping; show
/// the disclosure.
public struct ExpandableOverview: View {
    let text: String
    @State private var expanded = false
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    /// True when the line-limited render is shorter than the
    /// unlimited render — i.e. tapping "Show more" would actually
    /// reveal new text. The +0.5 slop absorbs sub-pixel rounding
    /// from SwiftUI's text layout.
    private var isTruncated: Bool { fullHeight > clampedHeight + 0.5 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: ClampedHeightKey.self,
                            value: g.size.height
                        )
                    }
                )
                .background(alignment: .topLeading) {
                    // Hidden, unlimited copy used as a measuring
                    // stick. Same font, same width (the background
                    // container takes the modified view's width), so
                    // its full rendered height tells us whether
                    // `lineLimit(4)` would clip. `opacity(0)` lets
                    // SwiftUI actually lay it out; `.allowsHitTesting`
                    // off and `.accessibilityHidden` keep it out of
                    // VoiceOver / event handling.
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
            if !expanded && isTruncated {
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
