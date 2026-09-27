import SwiftUI

// The detached NSWindow + NSHostingController doesn't bridge NavigationStack's automatic back
// button, so views relying on it (DetailView) draw their own back affordance when this is true.

private struct IsDetachedWindowKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var isDetachedWindow: Bool {
        get { self[IsDetachedWindowKey.self] }
        set { self[IsDetachedWindowKey.self] = newValue }
    }
}
