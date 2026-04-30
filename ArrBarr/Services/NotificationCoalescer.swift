import Foundation
import UserNotifications

extension QueueItem.Source {
    var serviceKind: ServiceKind {
        switch self {
        case .radarr: return .radarr
        case .sonarr: return .sonarr
        case .lidarr: return .lidarr
        }
    }
}

/// Coalesces queue-event notifications into one banner per arr per 60s window.
/// Without this, a Sonarr import of a 10-episode pack fires 10 banners in a burst.
@MainActor
final class NotificationCoalescer {
    static let categoryIdentifier = "ARRBARR_QUEUE_EVENT"
    static let openActionIdentifier = "ARRBARR_OPEN"
    static let userInfoBaseURLKey = "arrBaseURL"

    private let window: TimeInterval = 60
    private let configStore: ConfigStore
    private var pending: [QueueItem.Source: [QueueItem]] = [:]
    private var flushTimer: Timer?

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    func enqueue(_ item: QueueItem) {
        pending[item.source, default: []].append(item)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: window, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func flush() {
        flushTimer = nil
        let snapshot = pending
        pending.removeAll()
        for (source, items) in snapshot where !items.isEmpty {
            post(source: source, items: items)
        }
    }

    private func post(source: QueueItem.Source, items: [QueueItem]) {
        let cfg = configStore.config(for: source.serviceKind)

        let content = UNMutableNotificationContent()
        content.title = source.displayName
        if items.count == 1 {
            let item = items[0]
            content.subtitle = item.title
            var body = item.status.displayName
            if let q = item.quality { body += " · \(q)" }
            if item.isUpgrade { body += " · " + String(localized: "Upgrade") }
            content.body = body
        } else {
            let titles = items.prefix(3).map(\.title).joined(separator: ", ")
            let format = String(localized: "%lld items: %@")
            content.body = String(format: format, items.count, titles)
        }
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        if !cfg.baseURL.isEmpty {
            content.userInfo[Self.userInfoBaseURLKey] = cfg.baseURL
        }

        let req = UNNotificationRequest(
            identifier: "arrbarr.\(source.rawValue).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}

enum ArrActivityURLBuilder {
    /// Constructs `<baseURL>/activity/queue` — the same path on Radarr, Sonarr and Lidarr web UIs.
    static func queueURL(forBase base: String) -> URL? {
        guard !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/activity/queue")
    }
}
