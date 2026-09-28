import Foundation

/// Short on purpose: it shares the row with a 26×38 poster and title. Callers localize it.
nonisolated enum QueueSearchStatusLabel {
    static func label(for item: QueueItem) -> String {
        switch item.status {
        case .downloading:
            if item.progress > 0 {
                let pct = Int((item.progress * 100).rounded())
                if let eta = item.timeLeft, !eta.isEmpty {
                    return "\(pct)% · \(eta)"
                }
                return "\(pct)%"
            }
            return "downloading"
        case .queued:     return "queued"
        case .paused:     return "paused"
        case .importing:  return "importing"
        case .completed:  return "completed"
        case .warning:    return "warning"
        case .failed:     return "failed"
        case .unknown:    return "queued"
        }
    }
}
