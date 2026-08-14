import Foundation

/// Live progress for a single download, read straight from the download client
/// (qBittorrent / SABnzbd / …) rather than the arr. The arr only re-polls its
/// client every so often, so its `/queue` progress lags the client's true
/// state; this is the fresher value the queue overlays on top (see
/// `DownloadProgressService` + `QueueAggregator`).
public struct DownloadProgress: Sendable, Equatable {
    /// 0...1 completion as the client reports it.
    public let progress: Double
    /// Bytes/sec when the client reports it. Not yet surfaced in the UI —
    /// carried so adding a live "speed" readout later needs no protocol change.
    public let downloadSpeed: Int64?

    public init(progress: Double, downloadSpeed: Int64? = nil) {
        // Clamp once here so the per-client sources don't each repeat it.
        self.progress = max(0, min(1, progress))
        self.downloadSpeed = downloadSpeed
    }
}

/// A download client that can report live progress for all of its active
/// downloads in **one batch call**, keyed by the id the arr queue carries for
/// each item (torrent hash / usenet nzo id), lowercased so matching is
/// case-insensitive across clients.
///
/// One protocol for every client → the cache + overlay never branch per client.
/// A client that can't (yet) report progress simply doesn't conform, and the
/// arr value stays as the fallback. Conformers are actors, so the service can
/// fan the fetches out in parallel.
public protocol DownloadProgressSource: Sendable {
    /// Live progress for the given download ids, keyed by lowercased id.
    ///
    /// `ids` is what the arrs' queues actually reference — a hint, not a
    /// contract. Clients whose progress endpoint can target ids narrow the
    /// request with it; the rest ignore it, because their endpoint is already
    /// scoped to the queue (SABnzbd's `mode=queue`, NZBGet's `listgroups`)
    /// and there is nothing to narrow. Returning extra entries is harmless —
    /// the overlay matches by id.
    ///
    /// It matters most for the torrent clients: a seedbox holds every
    /// completed torrent forever, so an unfiltered listing grows without bound
    /// while the set we care about stays the size of the queue.
    func fetchProgress(ids: Set<String>) async throws -> [String: DownloadProgress]
}
