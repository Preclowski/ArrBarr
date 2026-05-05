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

    public init(
        id: String, source: QueueItem.Source, date: Date, eventType: EventType,
        title: String, subtitle: String?, sourceTitle: String?, quality: String?,
        customFormats: [String], customFormatScore: Int
    ) {
        self.id = id; self.source = source; self.date = date; self.eventType = eventType
        self.title = title; self.subtitle = subtitle; self.sourceTitle = sourceTitle
        self.quality = quality; self.customFormats = customFormats; self.customFormatScore = customFormatScore
    }

    public enum EventType: String {
        case grabbed
        case imported
        case failed
        case deleted
        case other

        public var displayName: String {
            switch self {
            case .grabbed: return "Grabbed"
            case .imported: return "Imported"
            case .failed: return "Failed"
            case .deleted: return "Deleted"
            case .other: return "Event"
            }
        }

        public var symbol: String {
            switch self {
            case .grabbed: return "arrow.down.circle.fill"
            case .imported: return "tray.and.arrow.down.fill"
            case .failed: return "xmark.circle.fill"
            case .deleted: return "trash.fill"
            case .other: return "circle.fill"
            }
        }

        public static func parse(_ raw: String?) -> EventType {
            switch raw?.lowercased() {
            case "grabbed": return .grabbed
            case "downloadfolderimported", "episodefileimported", "moviefileimported": return .imported
            case "downloadfailed", "downloadignored": return .failed
            case "moviefiledeleted", "episodefiledeleted": return .deleted
            default: return .other
            }
        }
    }
}
