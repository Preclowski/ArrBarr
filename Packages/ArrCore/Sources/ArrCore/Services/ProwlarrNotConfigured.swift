import Foundation

/// Thrown by `ConfigStore.testProwlarr()` when there's nothing to test yet.
nonisolated struct ProwlarrNotConfigured: LocalizedError {
    var errorDescription: String? { String(localized: "Service not configured", bundle: .module) }
}
