import Foundation
import os

/// The Library grid's last-known contents, on disk, per arr.
///
/// MediaKit's store already keeps the arrs' raw library payloads across
/// launches — but "raw" is the problem: Radarr's is 5 MB of JSON for a few
/// thousand movies, and reading it back means a SQLite read plus a full
/// decode plus the unify and the sort before a single cover can be drawn.
/// That is what the user saw as "the Library loads from zero every time".
///
/// This holds the finished projection instead — the same `LibraryEntry`
/// values the grid renders, a fraction of the size — so the first visit of a
/// session paints from it immediately and the real load runs behind it.
/// Same idea, and the same atomic-write discipline, as the Upcoming snapshot
/// in `WidgetDataStore`.
nonisolated enum LibrarySnapshotStore {
    /// Bumped whenever `LibraryEntry` changes shape. An old file simply fails
    /// to decode and is ignored, but the version makes that intent explicit
    /// rather than leaving it to a decoding error.
    private static let version = 1
    private static let log = Logger(category: "Library")

    private struct Snapshot: Codable {
        let version: Int
        /// Which server produced it (`ServiceConfig.identityFingerprint`). A
        /// snapshot of one profile must never paint another's grid — demo mode
        /// shares this directory with the real profile, and a re-pointed arr
        /// is a different library under the same source name.
        let fingerprint: String
        let savedAt: Date
        let entries: [LibraryEntry]
    }

    /// Writes are serialised and off the caller's thread: a projection commits
    /// on the main actor, and a file write there is a frame the user pays for.
    private static let queue = DispatchQueue(label: "pl.incred.ArrBarr.library-snapshot", qos: .utility)

    private static func fileURL(_ source: QueueItem.Source) -> URL? {
        #if DEBUG
        // Under tests this must never touch the developer's real Application
        // Support: a snapshot left there leaks between runs and, worse, into
        // the next test's "cold start" (it did — a suite asserting the
        // unreachable-arr state found a grid waiting for it). Same seam and
        // same reasoning as `WidgetDataStore`.
        if let dir = WidgetDataStore.testSnapshotDirectory() {
            return dir.appendingPathComponent("library-\(source.rawValue).json")
        }
        #endif
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("library-\(source.rawValue).json")
    }

    /// The saved grid for a source, or nil when there is none (or it is from an
    /// older shape). Decoding runs off the main actor — the caller awaits it.
    static func load(_ source: QueueItem.Source, fingerprint: String) async -> [LibraryEntry]? {
        await Task.detached(priority: .userInitiated) { () -> [LibraryEntry]? in
            guard let url = fileURL(source), let data = try? Data(contentsOf: url) else { return nil }
            guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.version == version, snapshot.fingerprint == fingerprint,
                  !snapshot.entries.isEmpty else { return nil }
            return snapshot.entries
        }.value
    }

    /// Replace a source's snapshot. Fire-and-forget: a failed write costs the
    /// next launch a slower first paint and nothing else.
    static func save(_ entries: [LibraryEntry], source: QueueItem.Source, fingerprint: String) {
        guard !entries.isEmpty, let url = fileURL(source) else { return }
        let snapshot = Snapshot(version: version, fingerprint: fingerprint, savedAt: Date(), entries: entries)
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("library snapshot write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
