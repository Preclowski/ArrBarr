import SwiftUI

// The detached NSWindow + NSHostingController doesn't bridge NavigationStack's automatic back
// button, so views relying on it (DetailView) draw their own back affordance when this is true.

public extension EnvironmentValues {
    @Entry var isDetachedWindow: Bool = false
}
