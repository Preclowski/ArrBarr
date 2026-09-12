import Foundation

public struct HistoryItem: Identifiable, Equatable {
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
    /// Set by the arr clients on per-file rows that arrived as one download
    /// (a Lidarr album, a Sonarr season pack) so `collapsingBatches` can fold
    /// them into a single row. `pairingUpgrades` copies it onto the deletions
    /// such a batch caused, so those fold too.
    public internal(set) var groupHint: GroupHint?
    /// Number of per-file rows folded into this one; 1 = a plain row.
    public internal(set) var groupedCount: Int
    /// Poster of the movie / series / artist the event belongs to, from the
    /// record the arr embeds in the history page. Nil when it didn't embed one
    /// (a title deleted since).
    public let posterURL: URL?
    public let posterRequiresAuth: Bool
    /// The arr record the event belongs to — movie, series or artist id. What
    /// the row opens.
    public let arrId: Int?
    /// The one file slot the event touched: the movie for Radarr / Whisparr,
    /// the episode for Sonarr. Nil for Lidarr, whose files are tracks under an
    /// album-level event. Upgrade pairing only matches events on the same slot.
    public let fileKey: String?
    public let downloadId: String?
    public let downloadClient: String?
    public let indexer: String?
    /// Release size (grabs) or file size (imports, deletions), in bytes. Nil on
    /// a folded import or deletion, where one file's size isn't the batch's.
    public internal(set) var size: Int64?
    /// Why a file was deleted — the arr's raw reason ("Upgrade", "Manual",
    /// "MissingFromDisk"). Nil on every other event.
    public let deleteReason: String?
    /// The file on disk when the history was fetched, where the arr embeds it
    /// (Radarr's movie record). Only meaningful to a grab that hasn't imported.
    public let fileOnDisk: FileSnapshot?
    /// Whether the title had a file when the history was fetched; nil when the
    /// arr didn't say.
    public let hadFileOnDisk: Bool?
    /// The file this event's release replaced — or, for a grab still on its
    /// way, would replace. Filled in by `pairingUpgrades`.
    public internal(set) var replaced: FileSnapshot?
    /// Upgrade or new download; nil when the history can't tell.
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

    /// One side of an upgrade comparison — the same facts `UpgradeDiffView`
    /// draws per column.
    public struct FileSnapshot: Equatable {
        public let quality: String?
        public let score: Int?
        public let size: Int64?
        public let formats: [String]
        public let filename: String?

        public init(quality: String?, score: Int?, size: Int64?, formats: [String], filename: String?) {
            self.quality = quality; self.score = score; self.size = size
            self.formats = formats; self.filename = filename
        }

        init(file: ArrFile) {
            self.init(quality: file.quality?.name, score: file.customFormatScore, size: file.size,
                      formats: (file.customFormats ?? []).map(\.name), filename: file.relativePath)
        }

        /// The file a deletion event removed, as that event recorded it.
        init(deleted event: HistoryItem) {
            self.init(quality: event.quality, score: event.customFormatScore, size: event.size,
                      formats: event.customFormats, filename: event.sourceTitle)
        }
    }

    /// Identity of a multi-file batch. `key` ties together the rows of one
    /// download+album/season; `collapsedSubtitle` replaces the per-file
    /// subtitle on the folded row (nil keeps the newest row's own subtitle).
    public struct GroupHint: Equatable {
        public let key: String
        public let collapsedSubtitle: String?

        public init(key: String, collapsedSubtitle: String? = nil) {
            self.key = key
            self.collapsedSubtitle = collapsedSubtitle
        }
    }

    /// What a history list shows: upgrades paired first — pairing needs the
    /// per-file rows — then grab, import and replaced-file batches folded.
    public static func prepared(_ items: [HistoryItem]) -> [HistoryItem] {
        collapsingBatches(pairingUpgrades(items))
    }

    // MARK: - Upgrade pairing

    /// How far apart an import and the deletion of the file it replaced may be
    /// logged. The arr writes both in one import pass, seconds apart.
    static let upgradePairingWindow: TimeInterval = 10 * 60

    /// Works out what each grab and import replaced, from the history alone.
    ///
    /// - An import that upgraded a file is logged next to a deletion of the
    ///   old file on the same slot, reason "Upgrade" — that deletion IS the
    ///   old side of the diff. An import with no such deletion was new. The
    ///   deletion also joins the import's batch, so a season pack's N
    ///   replaced episodes fold like its N imports do.
    /// - A grab that has imported since takes its import's answer (matched on
    ///   download id): the file on disk now is the grab itself, so it can't
    ///   be the baseline. A grab that hasn't imported compares against the
    ///   file on disk now, which is still the one it's going to replace.
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

    /// Fold runs of per-file rows that share a batch (same source, event type,
    /// group key and quality) into one row carrying the batch size — a season
    /// pack's per-episode grabs, imports and replaced files, an album's
    /// per-track imports. Order is preserved: the folded row sits where the
    /// batch's newest row was. Unhinted rows and failures pass through.
    ///
    /// A folded row keeps whether the batch was an upgrade but drops the diff
    /// and, except on a grab (one release, one size), the size: the per-file
    /// values differ, and one of them standing for the whole pack is wrong.
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

    /// The history list's sections: one per whole hour ago for the last day,
    /// then one per whole day — hour sections further back would be mostly
    /// "73 hours ago" headers over a single row.
    public enum TimeBucket: Hashable, Comparable {
        /// Whole hours ago, 0...23; 0 is the last hour.
        case hours(Int)
        /// Whole days ago, from 1.
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

    /// Items split into age sections, newest section first. Order within a
    /// section is the caller's (newest first, as the arrs return it).
    public static func grouped(_ items: [HistoryItem], now: Date) -> [TimeGroup] {
        var byBucket: [TimeBucket: [HistoryItem]] = [:]
        for item in items {
            byBucket[TimeBucket.of(item.date, now: now), default: []].append(item)
        }
        return byBucket.keys.sorted().map { TimeGroup(bucket: $0, items: byBucket[$0] ?? []) }
    }

    public enum EventType: String {
        case grabbed
        case imported
        case failed
        case deleted
        case other

        /// Catalog key of the event's name. Views resolve it through
        /// `AppLocalized` so a live language switch reaches it.
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

extension Dictionary where Key == String, Value == JSONValue {
    /// One value of a history record's `data` bag as text. The arrs send every
    /// value there as a string; a bare number is accepted too.
    func historyString(_ key: String) -> String? {
        switch self[key] {
        case .string(let s): return s.isEmpty ? nil : s
        case .number(let n): return String(Int64(n))
        default: return nil
        }
    }
}

/// One page of an arr's history as a client fetched it — raw per-file rows,
/// not yet paired or folded (`HistoryFeed` does that over every page loaded).
struct HistoryPage {
    let items: [HistoryItem]
    let hasMore: Bool
}
