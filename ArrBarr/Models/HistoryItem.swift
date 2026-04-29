import Foundation

struct HistoryItem: Identifiable, Equatable {
    let id: String
    let source: QueueItem.Source
    let date: Date
    let eventType: EventType
    let title: String
    let subtitle: String?
    let sourceTitle: String?
    let quality: String?
    let customFormats: [String]
    let customFormatScore: Int

    enum EventType: String {
        case grabbed
        case imported
        case failed
        case deleted
        case other

        var displayName: String {
            switch self {
            case .grabbed: return "Grabbed"
            case .imported: return "Imported"
            case .failed: return "Failed"
            case .deleted: return "Deleted"
            case .other: return "Event"
            }
        }

        var symbol: String {
            switch self {
            case .grabbed: return "arrow.down.circle.fill"
            case .imported: return "tray.and.arrow.down.fill"
            case .failed: return "xmark.circle.fill"
            case .deleted: return "trash.fill"
            case .other: return "circle.fill"
            }
        }

        static func parse(_ raw: String?) -> EventType {
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
