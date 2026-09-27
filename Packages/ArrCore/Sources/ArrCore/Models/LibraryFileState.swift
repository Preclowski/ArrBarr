import Foundation
import MediaKit

// MARK: - File state
//
// The one mapping from arr payloads to "how much of this is on disk", so the Library tab, detail heroes
// and ownership chips can't disagree.

/// Summed from Sonarr's per-season statistics: counting the episode list would call every ongoing
/// series half-missing, since unaired episodes are in it.
nonisolated struct EpisodeFileCounts: Equatable, Sendable {
    let have: Int
    let total: Int

    var isComplete: Bool { total > 0 && have >= total }

    init(have: Int, total: Int) {
        self.have = have
        self.total = total
    }

    init(seasons: [(have: Int?, total: Int?)]) {
        self.init(have: seasons.reduce(0) { $0 + ($1.have ?? 0) },
                  total: seasons.reduce(0) { $0 + ($1.total ?? 0) })
    }
}

nonisolated extension LibraryEntry.FileState {
    /// Complete wins even when unmonitored. `monitored == nil` means not known yet, not unmonitored.
    static func resolve(monitored: Bool?, complete: Bool, partial: Bool, available: Bool = true) -> Self {
        if complete { return .complete }
        if monitored == false { return .unmonitored }
        if partial { return .partial }
        return available ? .missing : .notAvailable
    }

    /// Single-file media: Radarr and Whisparr.
    static func movie(monitored: Bool?, hasFile: Bool, available: Bool = true) -> Self {
        resolve(monitored: monitored, complete: hasFile, partial: false, available: available)
    }

    /// Nothing aired yet (`total == 0`) is not the same as nothing grabbed.
    static func series(monitored: Bool?, counts: EpisodeFileCounts) -> Self {
        resolve(monitored: monitored, complete: counts.isComplete,
                partial: counts.have > 0, available: counts.total > 0)
    }
}

nonisolated extension ArrSeries {
    var episodeFileCounts: EpisodeFileCounts {
        EpisodeFileCounts(seasons: (seasons ?? []).map {
            (have: $0.statistics?.episodeFileCount, total: $0.statistics?.episodeCount)
        })
    }
}

// MARK: - Ownership

/// `isDownloaded` is about the disk, not the monitored flag: an unmonitored film with a file is downloaded.
nonisolated public struct LibraryOwnership: Equatable, Sendable {
    public let arrId: Int
    public let isDownloaded: Bool
}

nonisolated extension ArrMovie {
    var ownership: LibraryOwnership? {
        id.map { LibraryOwnership(arrId: $0, isDownloaded: hasFile == true) }
    }
}

nonisolated extension ArrSeries {
    var ownership: LibraryOwnership? {
        id.map { LibraryOwnership(arrId: $0, isDownloaded: episodeFileCounts.isComplete) }
    }
}

nonisolated extension ArrArtist {
    var ownership: LibraryOwnership? {
        id.map { id in
            let total = statistics?.trackCount ?? 0
            let have = statistics?.trackFileCount ?? 0
            return LibraryOwnership(arrId: id, isDownloaded: total > 0 && have >= total)
        }
    }
}
