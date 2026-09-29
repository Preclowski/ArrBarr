#if os(macOS)
import Foundation
import ServiceManagement
import os

/// The login item's state lives in the system (the user can remove it in System Settings), so it is read,
/// never stored.
enum LaunchAtLogin {
    private static let logger = Logger(category: "LaunchAtLogin")

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            logger.error("LaunchAtLogin toggle failed: \(error.logKind, privacy: .public): \(error.localizedDescription, privacy: .private)")
        }
        // Registered but not yet allowed: only the user can approve it, in System Settings.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
#endif
