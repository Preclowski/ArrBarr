import SwiftUI

/// Inline middle-dot separator. Used between metadata fields like
/// `1.2 GB · 720p · −20 min`. Centralised so we don't ship 30+ copies
/// of the raw middle-dot glyph across views, and so the
/// glyph is wrapped in `Text(verbatim:)` (not a localizable key).
struct SeparatorDot: View {
    var body: some View {
        Text(verbatim: "·").foregroundStyle(.tertiary)
    }
}
