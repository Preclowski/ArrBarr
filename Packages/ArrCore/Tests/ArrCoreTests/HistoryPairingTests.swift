import Foundation
import Testing
@testable import ArrCore

@Suite("History upgrade pairing and time sections")
struct HistoryPairingTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func event(
        _ id: String, _ type: HistoryItem.EventType, minutesAgo: Double = 0,
        fileKey: String? = "movie-1", downloadId: String? = nil, reason: String? = nil,
        quality: String? = "Bluray-2160p", formats: [String] = [], score: Int = 0, size: Int64? = nil,
        fileOnDisk: HistoryItem.FileSnapshot? = nil, hadFile: Bool? = nil,
        hint: HistoryItem.GroupHint? = nil
    ) -> HistoryItem {
        HistoryItem(
            id: id, source: .radarr, date: now.addingTimeInterval(-minutesAgo * 60), eventType: type,
            title: "Movie", subtitle: nil, sourceTitle: "\(id).mkv", quality: quality,
            customFormats: formats, customFormatScore: score, groupHint: hint,
            fileKey: fileKey, downloadId: downloadId, size: size, deleteReason: reason,
            fileOnDisk: fileOnDisk, hadFileOnDisk: hadFile
        )
    }

    @Test("An import logged beside an Upgrade deletion diffs against the deleted file")
    func importPairsWithUpgradeDeletion() {
        let items = [
            event("imp", .imported, minutesAgo: 10, downloadId: "d1", formats: ["DV"], score: 900),
            event("del", .deleted, minutesAgo: 10, reason: "Upgrade", quality: "WEB-DL 1080p",
                  formats: ["AMZN"], score: 200, size: 3_000),
        ]
        let out = HistoryItem.pairingUpgrades(items)
        #expect(out[0].isUpgrade == true)
        #expect(out[0].replaced == HistoryItem.FileSnapshot(
            quality: "WEB-DL 1080p", score: 200, size: 3_000, formats: ["AMZN"], filename: "del.mkv"))
        #expect(out[1].replaced == nil)
        #expect(out[1].isUpgrade == nil)
    }

    @Test("A manual deletion, another slot's or a distant one is not what an import replaced")
    func unrelatedDeletionsDontPair() {
        let items = [
            event("imp", .imported),
            event("manual", .deleted, reason: "Manual"),
            event("other", .deleted, fileKey: "movie-2", reason: "Upgrade"),
            event("old", .deleted, minutesAgo: 60, reason: "Upgrade"),
        ]
        let out = HistoryItem.pairingUpgrades(items)
        #expect(out[0].isUpgrade == false)
        #expect(out[0].replaced == nil)
    }

    @Test("A grab that imported since takes its import's diff, not the file on disk now")
    func importedGrabUsesItsImport() {
        let nowOnDisk = HistoryItem.FileSnapshot(
            quality: "Bluray-2160p", score: 900, size: 9, formats: ["DV"], filename: "new.mkv")
        let items = [
            event("imp", .imported, minutesAgo: 10, downloadId: "d1"),
            event("del", .deleted, minutesAgo: 10, reason: "Upgrade", quality: "WEB-DL 1080p"),
            event("grab", .grabbed, minutesAgo: 30, downloadId: "d1", fileOnDisk: nowOnDisk, hadFile: true),
        ]
        let out = HistoryItem.pairingUpgrades(items)
        #expect(out[2].isUpgrade == true)
        #expect(out[2].replaced?.quality == "WEB-DL 1080p")
    }

    @Test("A grab still on its way compares against the file on disk, or is new without one")
    func pendingGrabUsesFileOnDisk() {
        let onDisk = HistoryItem.FileSnapshot(
            quality: "WEB-DL 1080p", score: 100, size: 5, formats: [], filename: "old.mkv")
        let upgrade = HistoryItem.pairingUpgrades([
            event("grab", .grabbed, downloadId: "d2", fileOnDisk: onDisk, hadFile: true),
        ])
        #expect(upgrade[0].replaced == onDisk)
        #expect(upgrade[0].isUpgrade == true)

        let fresh = HistoryItem.pairingUpgrades([event("grab", .grabbed, downloadId: "d3", hadFile: false)])
        #expect(fresh[0].replaced == nil)
        #expect(fresh[0].isUpgrade == false)
    }

    @Test("Events without a file slot (Lidarr) get no verdict")
    func noFileKeyNoVerdict() {
        let out = HistoryItem.pairingUpgrades([
            event("imp", .imported, fileKey: nil),
            event("grab", .grabbed, fileKey: nil, hadFile: true),
        ])
        #expect(out.allSatisfy { $0.isUpgrade == nil && $0.replaced == nil })
    }

    @Test("A season pack's grabs, imports and replaced files each fold into one row")
    func packFoldsPerEvent() {
        let hint = HistoryItem.GroupHint(key: "pack|s1", collapsedSubtitle: "Season 1")
        let imports = (1...2).flatMap { ep in [
            event("imp\(ep)", .imported, minutesAgo: 10, fileKey: "episode-\(ep)", downloadId: "pack",
                  size: 100, hint: hint),
            event("del\(ep)", .deleted, minutesAgo: 10, fileKey: "episode-\(ep)", reason: "Upgrade",
                  quality: "HDTV-720p", size: 40),
        ] }
        let grabs = (1...2).map { ep in
            event("grab\(ep)", .grabbed, minutesAgo: 30, fileKey: "episode-\(ep)", downloadId: "pack",
                  size: 900, hint: hint)
        }
        let out = HistoryItem.prepared(imports + grabs)
        #expect(out.map(\.eventType) == [.imported, .deleted, .grabbed])
        #expect(out.allSatisfy { $0.groupedCount == 2 && $0.subtitle == "Season 1" && $0.replaced == nil })
        #expect(out[0].isUpgrade == true)
        #expect(out[2].isUpgrade == true)
        // One release has one size; per-episode files don't add up to a row.
        #expect(out.map(\.size) == [nil, nil, 900])
    }

    @Test("A deletion nobody's import caused stays its own row")
    func unpairedDeletionsDontFold() {
        let out = HistoryItem.prepared([
            event("del1", .deleted, fileKey: "episode-1", reason: "Manual"),
            event("del2", .deleted, fileKey: "episode-2", reason: "Manual"),
        ])
        #expect(out.count == 2)
    }

    @Test("Sections are whole hours ago for a day, then whole days")
    func bucketBoundaries() {
        func bucket(minutesAgo: Double) -> HistoryItem.TimeBucket {
            .of(now.addingTimeInterval(-minutesAgo * 60), now: now)
        }
        #expect(bucket(minutesAgo: 59) == .hours(0))
        #expect(bucket(minutesAgo: 60) == .hours(1))
        #expect(bucket(minutesAgo: 5 * 60 + 59) == .hours(5))
        #expect(bucket(minutesAgo: 23 * 60 + 59) == .hours(23))
        #expect(bucket(minutesAgo: 24 * 60) == .days(1))
        #expect(bucket(minutesAgo: 3 * 24 * 60 + 5) == .days(3))
    }

    @Test("Sections come newest first and keep the order within each")
    func groupingOrder() {
        let items = [
            event("a", .grabbed, minutesAgo: 5),
            event("b", .grabbed, minutesAgo: 90),
            event("c", .grabbed, minutesAgo: 20),
        ]
        let groups = HistoryItem.grouped(items, now: now)
        #expect(groups.map(\.bucket) == [.hours(0), .hours(1)])
        #expect(groups[0].items.map(\.id) == ["a", "c"])
    }
}
