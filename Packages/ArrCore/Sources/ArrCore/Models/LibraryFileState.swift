import Foundation

// MARK: - File state
//
// The one mapping from arr payloads to "how much of this is on disk". The
// Library tab, the detail heroes and the ownership chip on search / Quiz /
// filmography rows all resolve through here. They used to carry three copies
// with two different series formulas, so the same show could read complete in
// one place and partial in the next.

/// Files on disk vs episodes expected, summed from Sonarr's per-season
/// statistics — the arr's own numbers. Counting the episode list instead would
/// call every ongoing series half-missing, since unaired episodes are in it too.
nonisolated public struct EpisodeFileCounts: Equatable, Sendable {
    public let have: Int
    public let total: Int

    /// Every counted episode has a file.
    public var isComplete: Bool { total > 0 && have >= total }

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
    /// Precedence: complete first — what's on disk is the answer even when the
    /// arr stopped monitoring it — then unmonitored, partial, and finally
    /// missing vs nothing-grabbable-yet. `monitored == nil` means "not known
    /// yet" (a detail payload still loading), not unmonitored.
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

nonisolated extension SonarrLibraryRecord {
    var episodeFileCounts: EpisodeFileCounts {
        EpisodeFileCounts(seasons: (seasons ?? []).map {
            (have: $0.statistics?.episodeFileCount, total: $0.statistics?.episodeCount)
        })
    }
}

nonisolated extension SonarrSeriesDetail {
    var episodeFileCounts: EpisodeFileCounts {
        EpisodeFileCounts(seasons: (seasons ?? []).map {
            (have: $0.statistics?.episodeFileCount, total: $0.statistics?.episodeCount)
        })
    }
}

// MARK: - Ownership

/// A title's match in the user's library: which arr record it is, and whether
/// its files are on disk. What an ownership chip needs — "Downloaded" or
/// "library" — without a request of its own.
///
/// `isDownloaded` is about the disk, not the monitored flag: an unmonitored
/// film with a file is still downloaded.
nonisolated public struct LibraryOwnership: Equatable, Sendable {
    public let arrId: Int
    public let isDownloaded: Bool
}

nonisolated extension RadarrLibraryRecord {
    var ownership: LibraryOwnership? {
        id.map { LibraryOwnership(arrId: $0, isDownloaded: hasFile == true) }
    }
}

nonisolated extension SonarrLibraryRecord {
    var ownership: LibraryOwnership? {
        id.map { LibraryOwnership(arrId: $0, isDownloaded: episodeFileCounts.isComplete) }
    }
}

nonisolated extension WhisparrLibraryRecord {
    var ownership: LibraryOwnership? {
        id.map { LibraryOwnership(arrId: $0, isDownloaded: hasFile == true) }
    }
}

nonisolated extension LidarrLibraryRecord {
    var ownership: LibraryOwnership? {
        id.map { id in
            let total = statistics?.trackCount ?? 0
            let have = statistics?.trackFileCount ?? 0
            return LibraryOwnership(arrId: id, isDownloaded: total > 0 && have >= total)
        }
    }
}
