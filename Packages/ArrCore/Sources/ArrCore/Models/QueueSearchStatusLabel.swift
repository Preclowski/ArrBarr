import Foundation

/// Compact trailing label for the IN QUEUE row in the queue-search
/// status-grouped layout. Short on purpose — sits next to a 26×38
/// poster + title and shares the row with library/new rows that show
/// chevrons / plus glyphs. Returns a plain `String`; callers wrap it
/// in `Text(_:bundle:)` for localization.
public enum QueueSearchStatusLabel {
    public static func label(for item: QueueItem) -> String {
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
