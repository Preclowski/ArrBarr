import SwiftUI

/// Semantic spacing and radii. One-off optical nudges stay raw literals; a token would hide the intent.
enum Tokens {
    enum Spacing {
        /// Tighter on the narrow macOS popover, where 12 pt read as oversized side gaps.
        #if os(macOS)
        public static let queueRowH: CGFloat = 7
        #else
        static let queueRowH: CGFloat = 12
        #endif
    }

    enum Radius {
        static let chip: CGFloat = 4
        static let card: CGFloat = 6
        static let panel: CGFloat = 10
        /// 12 pt — full-width suggestion / prompt rows in the chat empty state.
        static let suggestionRow: CGFloat = 12
        /// 14 pt — filter chips and filter pills.
        static let filterPill: CGFloat = 14
    }
}
