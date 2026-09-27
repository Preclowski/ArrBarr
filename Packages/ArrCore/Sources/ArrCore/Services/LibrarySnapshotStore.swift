import Foundation
import os

/// The Library grid's finished projection, on disk per arr, so a session's first visit paints
/// immediately (decoding MediaKit's raw payload, e.g. 5 MB for Radarr, is too slow).
nonisolated enum LibrarySnapshotStore {
    /// Bump when `LibraryEntry` changes shape.
    private static let version = 1
    private static let log = Logger(category: "Library")

    private struct Snapshot: Codable {
        let version: Int
        /// `ServiceConfig.identityFingerprint`: demo mode shares this directory, and a re-pointed arr is another library.
        let fingerprint: String
        let savedAt: Date
        let entries: [LibraryEntry]
    }

    /// Off the caller's thread: projections commit on the main actor.
    private static let queue = DispatchQueue(label: "pl.incred.ArrBarr.library-snapshot", qos: .utility)

    private static func fileURL(_ source: QueueItem.Source) -> URL? {
        #if DEBUG
        // Tests must never touch the real Application Support: a leftover snapshot leaks into the next test's cold start.
        if let dir = WidgetDataStore.testSnapshotDirectory() {
            return dir.appendingPathComponent("library-\(source.rawValue).json")
        }
        #endif
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("library-\(source.rawValue).json")
    }

    static func load(_ source: QueueItem.Source, fingerprint: String) async -> [LibraryEntry]? {
        await Task.detached(priority: .userInitiated) { () -> [LibraryEntry]? in
            guard let url = fileURL(source), let data = try? Data(contentsOf: url) else { return nil }
            guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.version == version, snapshot.fingerprint == fingerprint,
                  !snapshot.entries.isEmpty else { return nil }
            return snapshot.entries
        }.value
    }

    /// Fire-and-forget: a failed write only slows the next first paint.
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
