import SwiftUI

/// Set where a permanent detail pane makes tooltips redundant, or while a confirmation is up
/// (a tooltip window would sail over it). Also dismisses a tooltip already on screen.
public extension EnvironmentValues {
    @Entry var suppressRowTooltip: Bool = false
}
