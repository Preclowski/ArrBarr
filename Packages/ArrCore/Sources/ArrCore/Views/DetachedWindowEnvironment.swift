import SwiftUI

// Whether the surrounding content is hosted in the macOS detached window
// (Dock-icon mode) rather than the MenuBarExtra(.window) panel.
//
// It matters for navigation chrome: the MenuBarExtra panel is a SwiftUI-managed
// scene window, so `NavigationStack` renders its native `< Back` chevron in the
// titlebar for free. The detached window is a hand-built `NSWindow` +
// `NSHostingController`, where SwiftUI does NOT bridge NavigationStack's
// automatic back button (verified empirically — only explicit `.toolbar` items
// and `.navigationTitle` bridge). So views that rely on the automatic chevron
// (DetailView) must render their own in-content back affordance when detached.

private struct IsDetachedWindowKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var isDetachedWindow: Bool {
        get { self[IsDetachedWindowKey.self] }
        set { self[IsDetachedWindowKey.self] = newValue }
    }
}
