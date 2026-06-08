#if os(macOS)
import SwiftUI

/// macOS 15+ adds `.toolbarBackgroundVisibility(_:for:)` which finally
/// suppresses the inline NavigationStack toolbar fill that the older
/// `.toolbarBackground(.hidden, ...)` modifier alone doesn't catch
/// inside `MenuBarExtra(.window)`. Availability-gated so the package
/// still builds against macOS 14.
struct HiddenWindowToolbarBackgroundIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
#endif
