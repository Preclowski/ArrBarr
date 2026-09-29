import SwiftUI

/// `Text(verbatim:)` so the glyph is never a localizable key.
struct SeparatorDot: View {
    var body: some View {
        Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
    }
}
