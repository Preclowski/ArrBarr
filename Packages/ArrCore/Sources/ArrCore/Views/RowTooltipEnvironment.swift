import SwiftUI

/// Tooltips are unwelcome right now. Two reasons set this:
///
/// - a surface that already hosts a permanent detail pane (e.g. the macOS
///   desktop window's NavigationSplitView) — the same information is one click
///   away, so the tooltip would be redundant chrome;
/// - a modal confirmation is up (`confirmCenterHost`) — a tooltip is a floating
///   window and would sail straight over the alert.
///
/// Honoured by the hover timers AND by `tooltipPopover` itself, so it also
/// dismisses a tooltip that is already on screen.
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
