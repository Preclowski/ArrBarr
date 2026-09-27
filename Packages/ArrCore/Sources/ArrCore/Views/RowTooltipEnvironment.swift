import SwiftUI

/// Set where a permanent detail pane makes tooltips redundant, or while a confirmation is up
/// (a tooltip window would sail over it). Also dismisses a tooltip already on screen.
private struct SuppressRowTooltipKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var suppressRowTooltip: Bool {
        get { self[SuppressRowTooltipKey.self] }
        set { self[SuppressRowTooltipKey.self] = newValue }
    }
}
