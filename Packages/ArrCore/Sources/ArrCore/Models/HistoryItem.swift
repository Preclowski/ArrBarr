import Foundation

public struct HistoryItem: Identifiable, Equatable {
    public let id: String
    public let source: QueueItem.Source
    public let date: Date
    public let eventType: EventType
    public let title: String
    public let subtitle: String?
    public let sourceTitle: String?
    public let quality: String?
    public let customFormats: [String]
    public let customFormatScore: Int
    /// Set by the arr clients on per-file import rows that arrived as one
    /// download (a Lidarr album, a Sonarr season pack) so
    /// `collapsingImportBatches` can fold them into a single row.
    public let groupHint: GroupHint?
    /// Number of per-file rows folded into this one; 1 = a plain row.
    public let groupedCount: Int

    public init(
        id: String, source: QueueItem.Source, date: Date, eventType: EventType,
        title: String, subtitle: String?, sourceTitle: String?, quality: String?,
        customFormats: [String], customFormatScore: Int,
        groupHint: GroupHint? = nil, groupedCount: Int = 1
    ) {
        self.id = id; self.source = source; self.date = date; self.eventType = eventType
        self.title = title; self.subtitle = subtitle; self.sourceTitle = sourceTitle
        self.quality = quality; self.customFormats = customFormats; self.customFormatScore = customFormatScore
        self.groupHint = groupHint; self.groupedCount = groupedCount
    }

    /// Identity of a multi-file import batch. `key` ties together the rows of
    /// one download+album/season; `collapsedSubtitle` replaces the per-file
    /// subtitle on the folded row (nil keeps the newest row's own subtitle).
    public struct GroupHint: Equatable {
        public let key: String
        public let collapsedSubtitle: String?

        public init(key: String, collapsedSubtitle: String? = nil) {
            self.key = key
            self.collapsedSubtitle = collapsedSubtitle
        }
    }

    /// Fold runs of per-file import rows that share a batch (same source,
    /// group key and quality) into one row carrying the batch size. Order is
    /// preserved: the folded row sits where the batch's newest row was.
    /// Non-import rows and unhinted rows pass through untouched.
    public static func collapsingImportBatches(_ items: [HistoryItem]) -> [HistoryItem] {
        func batchKey(_ item: HistoryItem) -> String? {
            guard item.eventType == .imported, let hint = item.groupHint else { return nil }
            return "\(item.source.rawValue)|\(hint.key)|\(item.quality ?? "")"
        }
        var batchSizes: [String: Int] = [:]
        for item in items {
            if let key = batchKey(item) { batchSizes[key, default: 0] += 1 }
        }
        var emitted: Set<String> = []
        return items.compactMap { item in
            guard let key = batchKey(item), let size = batchSizes[key], size > 1 else { return item }
            guard emitted.insert(key).inserted else { return nil }
            return HistoryItem(
                id: item.id, source: item.source, date: item.date, eventType: item.eventType,
                title: item.title,
                subtitle: item.groupHint?.collapsedSubtitle ?? item.subtitle,
                sourceTitle: item.sourceTitle, quality: item.quality,
                customFormats: item.customFormats, customFormatScore: item.customFormatScore,
                groupHint: item.groupHint, groupedCount: size
            )
        }
    }

    public enum EventType: String {
        case grabbed
        case imported
        case failed
        case deleted
        case other

        public var displayName: String {
            switch self {
            case .grabbed:  return String(localized: "history.grabbed.button", bundle: .module)
            case .imported: return String(localized: "history.imported.button", bundle: .module)
            case .failed:   return String(localized: "history.failed.button", bundle: .module)
            case .deleted:  return String(localized: "history.deleted.button", bundle: .module)
            case .other:    return String(localized: "history.event.button", bundle: .module)
            }
        }

        public var symbol: String {
            switch self {
            // Outline (not filled) so "grabbed" (download just started / sent to
            // the client) doesn't read as the finished `tray…fill` import below.
            case .grabbed: return "arrow.down.circle"
            case .imported: return "tray.and.arrow.down.fill"
            case .failed: return "xmark.circle.fill"
            case .deleted: return "trash.fill"
            case .other: return "circle.fill"
            }
        }

        public static func parse(_ raw: String?) -> EventType {
            switch raw?.lowercased() {
            case "grabbed": return .grabbed
            case "downloadfolderimported", "episodefileimported", "moviefileimported",
                 "trackfileimported": return .imported
            case "downloadfailed", "downloadignored": return .failed
            case "moviefiledeleted", "episodefiledeleted", "trackfiledeleted": return .deleted
            default: return .other
            }
        }
    }
}
