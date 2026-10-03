import Foundation
import MediaKit

/// A release this title's history has seen before, as the arrs mark it in interactive search.
nonisolated struct ReleaseHistoryMark: Equatable, Sendable {
    /// `.grabbed` or `.failed`.
    let event: HistoryItem.EventType
    let date: Date

    /// Keyed by indexer guid. Only the grab carries the guid, so a failure is tied to it by download id.
    static func marks(from records: [ArrHistoryRecord]) -> [String: ReleaseHistoryMark] {
        // Oldest first, so the latest grab or failure of a release is the one that sticks.
        let dated = records
            .compactMap { r in r.date.flatMap(parseArrDate).map { (r, $0) } }
            .sorted { $0.1 < $1.1 }
        var marks: [String: ReleaseHistoryMark] = [:]
        var guidByDownload: [String: String] = [:]
        for (record, date) in dated {
            switch record.eventType?.lowercased() {
            case "grabbed":
                guard let guid = ArrCompositions.text(record.data, "guid") else { continue }
                if let id = record.downloadId { guidByDownload[id] = guid }
                marks[guid] = ReleaseHistoryMark(event: .grabbed, date: date)
            case "downloadfailed":
                guard let guid = ArrCompositions.text(record.data, "guid")
                        ?? record.downloadId.flatMap({ guidByDownload[$0] }) else { continue }
                marks[guid] = ReleaseHistoryMark(event: .failed, date: date)
            default:
                continue
            }
        }
        return marks
    }
}
