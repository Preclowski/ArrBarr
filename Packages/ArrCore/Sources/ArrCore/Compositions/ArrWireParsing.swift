import Foundation
import MediaKit

/// Servarr field parsing shared by every arr's row mappers.
nonisolated func parseArrDate(_ string: String) -> Date? {
    ArrDateParser.shared.parse(string)
}

/// Servarr dates come zoned, zoneless, or date-only; the memo keeps the row mappers cheap.
nonisolated private final class ArrDateParser: @unchecked Sendable {
    static let shared = ArrDateParser()
    private let lock = NSLock()
    private let zonedFractional = ISO8601DateFormatter()
    private let zoned = ISO8601DateFormatter()
    private let zoneless = ISO8601DateFormatter()
    private let dateOnly = ISO8601DateFormatter()
    private var dateOnlyZone: TimeZone
    private var memo: [String: Date?] = [:]
    private static let memoLimit = 2_048

    private init() {
        zonedFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        zoned.formatOptions = [.withInternetDateTime]
        zoneless.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        zoneless.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.formatOptions = [.withFullDate]
        dateOnlyZone = Calendar.current.timeZone
        dateOnly.timeZone = dateOnlyZone
    }

    func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let zone = Calendar.current.timeZone
        if zone != dateOnlyZone {
            dateOnlyZone = zone
            dateOnly.timeZone = zone
            memo.removeAll(keepingCapacity: true)
        }
        if let hit = memo[string] { return hit }
        let parsed = zonedFractional.date(from: string) ?? zoned.date(from: string) ?? zoneless.date(from: string) ?? dateOnly.date(from: string)
        if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
        memo[string] = parsed
        return parsed
    }
}

nonisolated func clampedBytes(_ value: Double?) -> Int64 {
    guard let value, value > 0 else { return 0 }
    guard value < Double(Int64.max) else { return Int64.max }
    return Int64(value)
}

nonisolated func parseProtocol(_ raw: String?) -> QueueItem.DownloadProtocol {
    switch raw?.lowercased() {
    case "usenet", "usenetdownloadprotocol": return .usenet
    case "torrent", "torrentdownloadprotocol": return .torrent
    default: return .unknown
    }
}

nonisolated func parseStatus(arrStatus: String?, trackedState: String?, trackedStatus: String? = nil) -> QueueItem.Status {
    let status = arrStatus?.lowercased()
    if status == "paused" { return .paused }
    func resolve() -> QueueItem.Status {
        if let tracked = trackedState?.lowercased() {
            switch tracked {
            case "downloading": return .downloading
            case "downloadfailed", "downloadfailedpending", "failedpending", "failed", "importfailed": return .failed
            case "importing", "importpending": return trackedStatus?.lowercased() == "warning" ? .warning : .importing
            case "imported": return .completed
            case "importblocked", "ignored": return .warning
            default: break
            }
        }
        switch status {
        case "downloading": return .downloading
        case "queued", "delay": return .queued
        case "completed": return .completed
        case "warning": return .warning
        case "failed": return .failed
        default: return .unknown
        }
    }
    let resolved = resolve()
    if resolved == .completed, trackedStatus?.lowercased() == "error" { return .failed }
    return resolved
}
