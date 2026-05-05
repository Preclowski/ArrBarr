import SwiftUI

/// Set to `true` in surfaces that already host a permanent detail pane
/// (e.g. the macOS desktop window's NavigationSplitView). When `true`, queue
/// rows skip the long-hover tooltip popover — the same information is one
/// click away in the detail pane, so the tooltip would be redundant chrome.
///
/// Default `false` — the menu-bar popover and any other compact surface
/// keep their tooltips since there's no other way to glance at pack contents
/// or per-episode meta.
private struct SuppressRowTooltipKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var suppressRowTooltip: Bool {
        get { self[SuppressRowTooltipKey.self] }
        set { self[SuppressRowTooltipKey.self] = newValue }
    }
}
