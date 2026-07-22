import Testing
@testable import ArrCore

/// With two clients of the same protocol configured, a pause/resume used to go
/// to whichever came first in a fixed priority order — so a Sonarr row backed
/// by Transmission had its hash sent to qBittorrent, which answers 200 OK for a
/// hash it doesn't know and does nothing. The row flipped to "paused"
/// optimistically and snapped back on the next refresh, with no error anywhere.
///
/// `QueueAggregator.route` is the seam: the arr already tells us which client
/// owns the download (`QueueItem.downloadClient`, the user's own name for it),
/// and this is the pure function that turns that name into a `ServiceKind`.
@Suite("Download-client routing")
struct DownloadClientRoutingTests {

    private let bothTorrent: [ServiceKind] = [.qbittorrent, .transmission]
    private let bothUsenet: [ServiceKind] = [.sabnzbd, .nzbget]

    /// The regression itself: the named client wins over the priority order.
    @Test("An item names the SECOND configured client → it is routed there")
    func namedClientWinsOverPriority() {
        #expect(QueueAggregator.route(clientNamed: "Transmission", among: bothTorrent) == .transmission)
        #expect(QueueAggregator.route(clientNamed: "NZBGet", among: bothUsenet) == .nzbget)
    }

    /// …and the first one still wins when it's the one named, so the fix isn't
    /// just "always pick the other".
    @Test("Naming the first configured client keeps routing there")
    func namedFirstClientStillWins() {
        #expect(QueueAggregator.route(clientNamed: "qBittorrent", among: bothTorrent) == .qbittorrent)
        #expect(QueueAggregator.route(clientNamed: "SABnzbd", among: bothUsenet) == .sabnzbd)
    }

    /// The arr's client name is free text the user typed, so matching has to
    /// survive the renaming people actually do.
    @Test("Renamed instances still resolve", arguments: [
        "Transmission (4K)", "transmission-sonarr", "TRANSMISSION", " Transmission ",
    ])
    func renamedTransmission(_ name: String) {
        #expect(QueueAggregator.route(clientNamed: name, among: bothTorrent) == .transmission)
    }

    @Test("Short-form and cased qBittorrent names resolve", arguments: [
        "qBit — 4K", "QBITTORRENT", "qbit-movies",
    ])
    func renamedQbittorrent(_ name: String) {
        #expect(QueueAggregator.route(clientNamed: name, among: bothTorrent) == .qbittorrent)
    }

    /// rTorrent's alternate spelling — the web UI people install in front of it
    /// is called ruTorrent and that is what ends up in the arr.
    @Test("ruTorrent resolves to rTorrent, not to the higher-priority client")
    func ruTorrentResolves() {
        #expect(QueueAggregator.route(clientNamed: "ruTorrent", among: [.qbittorrent, .rtorrent]) == .rtorrent)
    }

    /// A name we can't place must degrade to the old fixed-order behaviour
    /// rather than failing the action — the arr can report a client we don't
    /// have configured at all.
    @Test("An unrecognised or missing name falls back to the first configured client")
    func unknownNameFallsBack() {
        #expect(QueueAggregator.route(clientNamed: "Some Other Client", among: bothTorrent) == .qbittorrent)
        #expect(QueueAggregator.route(clientNamed: "", among: bothTorrent) == .qbittorrent)
        #expect(QueueAggregator.route(clientNamed: "   ", among: bothTorrent) == .qbittorrent)
        #expect(QueueAggregator.route(clientNamed: nil, among: bothTorrent) == .qbittorrent)
    }

    /// With one client there is nothing to disambiguate, and a mismatched name
    /// must not strand the action: the single configured client takes it.
    @Test("A single configured client takes the action whatever the name says")
    func singleClientIgnoresTheName() {
        #expect(QueueAggregator.route(clientNamed: "Transmission", among: [.qbittorrent]) == .qbittorrent)
        #expect(QueueAggregator.route(clientNamed: nil, among: [.deluge]) == .deluge)
    }

    @Test("Nothing configured routes nowhere")
    func nothingConfigured() {
        #expect(QueueAggregator.route(clientNamed: "Transmission", among: []) == nil)
    }

    /// `route` only ever sees candidates of the item's own protocol, and
    /// `ConfigStore.selectedDownloadClient` has to agree with the same list —
    /// pin the order so the two can't drift apart silently.
    @Test("Candidate sets stay protocol-scoped and in priority order")
    func candidateKinds() {
        #expect(QueueAggregator.candidateKinds(for: .torrent) == [.qbittorrent, .transmission, .rtorrent, .deluge])
        #expect(QueueAggregator.candidateKinds(for: .usenet) == [.sabnzbd, .nzbget])
        #expect(QueueAggregator.candidateKinds(for: .unknown).isEmpty)
    }

    /// Tokens are narrow on purpose — "torrent" alone would match qBittorrent,
    /// rTorrent and (via "BitTorrent") half the field. A usenet name must never
    /// pull a torrent client in, and vice versa.
    @Test("A name from the other protocol's client doesn't leak across")
    func tokensDoNotLeakAcrossProtocols() {
        #expect(QueueAggregator.route(clientNamed: "SABnzbd", among: bothTorrent) == .qbittorrent)
        #expect(QueueAggregator.route(clientNamed: "Transmission", among: bothUsenet) == .sabnzbd)
    }
}
