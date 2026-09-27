import Foundation
import os

#if os(macOS)
import ServiceManagement
#endif

enum LaunchAtLogin {
    private static let logger = Logger(category: "LaunchAtLogin")

    static func set(enabled: Bool) {
        #if os(macOS)
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            logger.error("LaunchAtLogin toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        #else
        // No equivalent on iOS — apps don't have a "launch at login" model.
        _ = enabled
        #endif
    }
}
