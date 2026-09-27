import SwiftUI

/// Semantic design tokens. Use these for spacing/radii that have a clear
/// role (section gutter, row inset, default corner) rather than reaching
/// for raw point values. One-off local tuning (a +1 nudge to optically
/// align a glyph, a `spacing: 3` to tighten a chip row) stays as a raw
/// literal — forcing it through a token would hide intent, not clarify
/// it.
///
/// New code should prefer these names. Existing raw values get migrated
/// opportunistically when the surrounding code is being touched anyway.
public enum Tokens {
    /// Spacing scale. Names map to *semantic role* — `queueRowH` is the
    /// horizontal inset inside a queue row, etc.
    public enum Spacing {
        /// Horizontal inset for queue rows + arr section headers. Tighter on
        /// the narrow macOS popover (12 pt read as oversized side gaps there)
        /// than on the full-width iOS list.
        #if os(macOS)
        public static let queueRowH: CGFloat = 7
        #else
        public static let queueRowH: CGFloat = 12
        #endif
    }

    /// Corner radii. `card` is the dominant value (rounded rectangles
    /// inside the popover); `chip` is the tighter rounding used on
    /// inline pills/badges.
    public enum Radius {
        public static let chip: CGFloat = 4
        public static let card: CGFloat = 6
        public static let panel: CGFloat = 10
        /// 12 pt — full-width suggestion / prompt rows in the chat empty state.
        public static let suggestionRow: CGFloat = 12
        /// 14 pt — filter chips and filter pills.
        public static let filterPill: CGFloat = 14
    }
}
