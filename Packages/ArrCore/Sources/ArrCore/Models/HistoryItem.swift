import Foundation

nonisolated public struct HistoryItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: QueueItem.Source
    public let date: Date
    public let eventType: EventType
    public let title: String
    public internal(set) var subtitle: String?
    public let sourceTitle: String?
    public let quality: String?
    public let customFormats: [String]
    public let customFormatScore: Int
    /// Set on per-file rows of one download (album, season pack) so `collapsingBatches`
    /// folds them; `pairingUpgrades` copies it onto the deletions the batch caused.
    public internal(set) var groupHint: GroupHint?
    /// Number of per-file rows folded into this one; 1 = a plain row.
    public internal(set) var groupedCount: Int
    /// From the record the arr embeds in the history page; nil for a title deleted since.
    public let posterURL: URL?
    public let posterRequiresAuth: Bool
    /// Movie, series or artist id.
    public let arrId: Int?
    /// The movie (Radarr / Whisparr) or episode (Sonarr); nil for Lidarr, whose files
    /// are tracks under an album-level event. Upgrade pairing matches on this slot.
    public let fileKey: String?
    public let downloadId: String?
    public let downloadClient: String?
    public let indexer: String?
    /// Nil on a folded import or deletion, where one file's size isn't the batch's.
    public internal(set) var size: Int64?
    /// The arr's raw reason ("Upgrade", "Manual", "MissingFromDisk").
    public let deleteReason: String?
    /// Only where the arr embeds it (Radarr's movie record); meaningful only to an unimported grab.
    public let fileOnDisk: FileSnapshot?
    public let hadFileOnDisk: Bool?
    public internal(set) var replaced: FileSnapshot?
    public internal(set) var isUpgrade: Bool?

    public init(
        id: String, source: QueueItem.Source, date: Date, eventType: EventType,
        title: String, subtitle: String?, sourceTitle: String?, quality: String?,
        customFormats: [String], customFormatScore: Int,
        groupHint: GroupHint? = nil, groupedCount: Int = 1,
        posterURL: URL? = nil, posterRequiresAuth: Bool = false,
        arrId: Int? = nil, fileKey: String? = nil, downloadId: String? = nil,
        downloadClient: String? = nil, indexer: String? = nil, size: Int64? = nil,
        deleteReason: String? = nil, fileOnDisk: FileSnapshot? = nil, hadFileOnDisk: Bool? = nil
    ) {
        self.id = id; self.source = source; self.date = date; self.eventType = eventType
        self.title = title; self.subtitle = subtitle; self.sourceTitle = sourceTitle
        self.quality = quality; self.customFormats = customFormats; self.customFormatScore = customFormatScore
        self.groupHint = groupHint; self.groupedCount = groupedCount
        self.posterURL = posterURL; self.posterRequiresAuth = posterRequiresAuth
        self.arrId = arrId; self.fileKey = fileKey; self.downloadId = downloadId
        self.downloadClient = downloadClient; self.indexer = indexer; self.size = size
        self.deleteReason = deleteReason; self.fileOnDisk = fileOnDisk; self.hadFileOnDisk = hadFileOnDisk
    }

    public struct FileSnapshot: Equatable, Sendable {
        public let quality: String?
        public let score: Int?
        public let size: Int64?
        public let formats: [String]
        public let filename: String?

        public init(quality: String?, score: Int?, size: Int64?, formats: [String], filename: String?) {
            self.quality = quality; self.score = score; self.size = size
            self.formats = formats; self.filename = filename
        }

        init(deleted event: HistoryItem) {
            self.init(quality: event.quality, score: event.customFormatScore, size: event.size,
                      formats: event.customFormats, filename: event.sourceTitle)
        }
    }

    /// `collapsedSubtitle` replaces the per-file subtitle on the folded row (nil keeps the newest row's).
    public struct GroupHint: Equatable, Sendable {
        public let key: String
        public let collapsedSubtitle: String?

        public init(key: String, collapsedSubtitle: String? = nil) {
            self.key = key
            self.collapsedSubtitle = collapsedSubtitle
        }
    }

    /// Pairing runs first because it needs the per-file rows.
    public static func prepared(_ items: [HistoryItem]) -> [HistoryItem] {
        collapsingBatches(pairingUpgrades(items))
    }

    // MARK: - Upgrade pairing

    /// The arr logs the import and the replaced file's deletion in one pass, seconds apart.
    static let upgradePairingWindow: TimeInterval = 10 * 60

    /// An upgrade import sits next to an "Upgrade" deletion on the same slot, which is its old side.
    /// An imported grab takes its import's answer: the file on disk now is the grab itself.
    public static func pairingUpgrades(_ items: [HistoryItem]) -> [HistoryItem] {
        func removedFile(_ deletion: HistoryItem, replacedBy imported: HistoryItem) -> Bool {
            guard deletion.eventType == .deleted, deletion.source == imported.source,
                  deletion.fileKey == imported.fileKey,
                  deletion.deleteReason?.caseInsensitiveCompare("Upgrade") == .orderedSame else { return false }
            return abs(deletion.date.timeIntervalSince(imported.date)) <= upgradePairingWindow
        }
        func isImport(_ imported: HistoryItem, of grab: HistoryItem) -> Bool {
            guard imported.eventType == .imported, imported.source == grab.source,
                  imported.fileKey == grab.fileKey, let downloadId = grab.downloadId else { return false }
            return imported.downloadId == downloadId
        }

        var out = items
        for i in out.indices where out[i].eventType == .imported && out[i].fileKey != nil {
            let imported = out[i]
            let deletionIndex = out.firstIndex { removedFile($0, replacedBy: imported) }
            if let deletionIndex {
                out[i].replaced = FileSnapshot(deleted: out[deletionIndex])
                if out[deletionIndex].groupHint == nil {
                    out[deletionIndex].groupHint = imported.groupHint
                }
            }
            out[i].isUpgrade = deletionIndex != nil
        }
        for g in out.indices where out[g].eventType == .grabbed && out[g].fileKey != nil {
            let grab = out[g]
            if let laterImport = out.first(where: { isImport($0, of: grab) }) {
                out[g].replaced = laterImport.replaced
                out[g].isUpgrade = laterImport.isUpgrade
            } else {
                out[g].replaced = grab.hadFileOnDisk == false ? nil : grab.fileOnDisk
                out[g].isUpgrade = grab.hadFileOnDisk
            }
        }
        return out
    }

    // MARK: - Batch folding

    /// The folded row sits where the batch's newest row was. It drops the diff and, except
    /// on a grab, the size: one file's value standing for the whole pack is wrong.
    public static func collapsingBatches(_ items: [HistoryItem]) -> [HistoryItem] {
        func batchKey(_ item: HistoryItem) -> String? {
            guard item.eventType == .imported || item.eventType == .grabbed || item.eventType == .deleted,
                  let hint = item.groupHint else { return nil }
            return "\(item.source.rawValue)|\(item.eventType.rawValue)|\(hint.key)|\(item.quality ?? "")"
        }
        var batches: [String: [HistoryItem]] = [:]
        for item in items {
            if let key = batchKey(item) { batches[key, default: []].append(item) }
        }
        var emitted: Set<String> = []
        return items.compactMap { item in
            guard let key = batchKey(item), let batch = batches[key], batch.count > 1 else { return item }
            guard emitted.insert(key).inserted else { return nil }
            var folded = item
            folded.subtitle = item.groupHint?.collapsedSubtitle ?? item.subtitle
            folded.groupedCount = batch.count
            folded.replaced = nil
            if item.eventType != .grabbed { folded.size = nil }
            if batch.contains(where: { $0.isUpgrade == true }) { folded.isUpgrade = true }
            return folded
        }
    }

    // MARK: - Time grouping

    /// Hours for the last day, then days: hour sections further back would be mostly single rows.
    public enum TimeBucket: Hashable, Comparable {
        /// 0...23; 0 is the last hour.
        case hours(Int)
        case days(Int)

        static func of(_ date: Date, now: Date) -> TimeBucket {
            let hours = max(0, Int(now.timeIntervalSince(date) / 3600))
            return hours < 24 ? .hours(hours) : .days(hours / 24)
        }
    }

    public struct TimeGroup: Identifiable, Equatable {
        public let bucket: TimeBucket
        public let items: [HistoryItem]
        public var id: TimeBucket { bucket }
    }

    /// Order within a section is the caller's.
    public static func grouped(_ items: [HistoryItem], now: Date) -> [TimeGroup] {
        var byBucket: [TimeBucket: [HistoryItem]] = [:]
        for item in items {
            byBucket[TimeBucket.of(item.date, now: now), default: []].append(item)
        }
        return byBucket.keys.sorted().map { TimeGroup(bucket: $0, items: byBucket[$0] ?? []) }
    }

    public enum EventType: String, Sendable {
        case grabbed
        case imported
        case failed
        case deleted
        case other

        /// Resolved through `AppLocalized` so a live language switch reaches it.
        var labelKey: String {
            switch self {
            case .grabbed:  return "history.grabbed.button"
            case .imported: return "history.imported.button"
            case .failed:   return "history.failed.button"
            case .deleted:  return "history.deleted.button"
            case .other:    return "history.event.button"
            }
        }

        public var displayName: String {
            String(localized: String.LocalizationValue(labelKey), bundle: .module)
        }

        public var symbol: String {
            switch self {
            // Outline so "grabbed" doesn't read as the finished `tray…fill` import.
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

/// Raw per-file rows, not yet paired or folded (`HistoryFeed` does that).
nonisolated struct HistoryPage: Sendable {
    let items: [HistoryItem]
    let hasMore: Bool
}
