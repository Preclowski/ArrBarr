import SwiftUI

@main
struct ArrBarrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // App protocol requires at least one Scene. The actual UI is driven by
    // NSStatusItem + NSPopover in AppDelegate (LSUIElement app, no dock icon).
    var body: some Scene {
        Settings { EmptyView() }
    }
}
