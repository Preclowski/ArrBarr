import Foundation

public struct NeedsYouItem: Identifiable, Equatable {
    public let id: String
    /// `nil` for a non-arr connection issue, identified by `service` instead.
    public let source: QueueItem.Source?
    public let service: MonitoredService?
    /// For an arr/service issue, the message itself; the trailing chip names the app.
    public let title: String
    public let subtitle: String
    public let detailLines: [String]
    public let item: QueueItem?
    /// Identical entries this row collapses; a pack warns once per episode.
    public var count: Int = 1

    public init(_ item: QueueItem) {
        self.item = item
        self.id = "needsyou.\(item.id)"
        self.source = item.source
        self.service = nil
        self.title = item.title
        self.subtitle = item.status == .warning
            ? String(localized: "queue.manualImportRequired.button", bundle: .module)
            : item.status.displayName
        self.detailLines = item.statusMessages
    }

    public init(
        arrIssue source: QueueItem.Source,
        id: String,
        message: String
    ) {
        self.item = nil
        self.id = id
        self.source = source
        self.service = nil
        self.title = message
        self.subtitle = ""
        self.detailLines = []
    }

    public init(
        serviceIssue service: MonitoredService,
        message: String
    ) {
        self.item = nil
        self.id = "needsyou.service.\(service.id)"
        self.source = nil
        self.service = service
        self.title = message
        self.subtitle = ""
        self.detailLines = []
    }
}
