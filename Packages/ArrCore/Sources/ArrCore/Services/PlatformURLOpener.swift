import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Opens an external URL using the platform's standard browser hand-off.
/// Uses `NSWorkspace.shared.open` on macOS and `UIApplication.shared.open`
/// on iOS. Replaces direct `NSWorkspace` references in shared views so
/// they compile for both platforms.
@MainActor
public enum PlatformURLOpener {
    public static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
