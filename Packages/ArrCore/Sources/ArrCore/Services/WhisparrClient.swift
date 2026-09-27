import Foundation
import MediaKit

/// Whisparr v3 is Radarr's vocabulary; the capability probe marks a v2 instance, whose movie resources are unsupported.
nonisolated public struct WhisparrClient: MovieArrClient {
    public let config: ServiceConfig
    public let source: QueueItem.Source = .whisparr

    init(config: ServiceConfig) { self.config = config }
}
