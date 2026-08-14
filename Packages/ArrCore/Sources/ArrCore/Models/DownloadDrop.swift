import Foundation

/// Which family of download client can take a given payload. A `.torrent` file
/// and a magnet link both go to a torrent client; an `.nzb` only ever goes to a
/// usenet client. This is what filters the arrs offered in the add sheet — an
/// arr whose download client can't speak the payload's protocol isn't a choice,
/// it's a dead end.
public enum DownloadKind: String, Sendable, CaseIterable {
    case torrent
    case usenet

    /// Read an arr's `protocol` field, whose spelling is NOT consistent across
    /// the family: Sonarr/Radarr/Whisparr (v3) serialise the enum's wire value
    /// (`"torrent"`, `"usenet"`), while Lidarr (v1) sends the enum's *name*
    /// (`"TorrentDownloadProtocol"`, `"UsenetDownloadProtocol"`). An exact
    /// match therefore silently discarded every Lidarr download client, and
    /// Lidarr never appeared as a drop destination.
    init?(arrProtocol raw: String) {
        let value = raw.lowercased()
        if value.contains("torrent") { self = .torrent }
        else if value.contains("usenet") || value.contains("nzb") { self = .usenet }
        else { return nil }
    }
}

/// One thing the user dropped, opened or clicked: a torrent/nzb file's bytes, or
/// a magnet link. Carries its own display name so the UI never has to re-derive
/// one from a URL it no longer holds.
public struct DownloadDrop: Identifiable, Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case file(Data, filename: String)
        case magnet(String)
    }

    public let id: UUID
    public let content: Content
    public let kind: DownloadKind
    /// What the add sheet shows — the file name, or a magnet's `dn` parameter.
    public let displayName: String

    public init(id: UUID = UUID(), content: Content, kind: DownloadKind, displayName: String) {
        self.id = id
        self.content = content
        self.kind = kind
        self.displayName = displayName
    }

    /// Build a drop from anything LaunchServices hands us — a dropped/opened
    /// file URL or a `magnet:` link. Returns nil for a URL we have no client
    /// for, so callers can ignore it rather than opening a sheet that can't
    /// complete. File reads happen here (once), not at add time: the security
    /// scope on a dropped URL doesn't outlive the drop handler.
    public init?(url: URL) {
        if url.scheme?.lowercased() == "magnet" {
            self.init(
                content: .magnet(url.absoluteString),
                kind: .torrent,
                displayName: Self.magnetName(url) ?? url.absoluteString
            )
            return
        }
        let kind: DownloadKind
        switch url.pathExtension.lowercased() {
        case "torrent": kind = .torrent
        case "nzb": kind = .usenet
        default: return nil
        }
        // A sandboxed app reaching a file it was handed (drop, Open With, Dock)
        // needs the scope open for the read itself. `startAccessing…` returns
        // false for URLs that don't need it — that's not a failure, so the read
        // is attempted either way and only its own error is fatal.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        self.init(content: .file(data, filename: url.lastPathComponent), kind: kind, displayName: url.lastPathComponent)
    }

    /// A magnet's human-readable name lives in `dn` (display name). Absent on
    /// bare hash-only magnets, which is why callers fall back to the raw link.
    private static func magnetName(_ url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        // `+` is a legal sub-delimiter, so URLComponents leaves it literal —
        // but trackers write `dn` in form encoding, where it means a space.
        // Without this the window titles a drop "The+Movie+2019".
        let raw = items.first { $0.name == "dn" }?.value?
            .replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (raw?.isEmpty == false) ? raw : nil
    }
}

/// A download client as *the arr* has it configured — the piece that makes the
/// import work. The category is the whole point: drop a file into the client
/// under `tv-sonarr` and Sonarr picks it up on its next scan; drop it in with no
/// category and it sits there orphaned.
public struct ArrDownloadClient: Identifiable, Sendable, Hashable {
    public let id: Int
    public let name: String
    /// The arr's implementation name — "QBittorrent", "Sabnzbd", … Mapped to our
    /// own `ServiceKind` by `serviceKind`, which is how we find the credentials
    /// to actually talk to it.
    public let implementation: String
    public let kind: DownloadKind
    public let category: String?

    /// Our `ServiceKind` for this arr client, or nil for a client ArrBarr has no
    /// support for (Flood, Hadouken, …) — those are filtered out of the picker
    /// rather than offered and then failing at add time.
    public var serviceKind: ServiceKind? {
        switch implementation.lowercased() {
        case "qbittorrent": return .qbittorrent
        case "transmission": return .transmission
        case "deluge": return .deluge
        case "rtorrent": return .rtorrent
        case "sabnzbd": return .sabnzbd
        case "nzbget": return .nzbget
        default: return nil
        }
    }
}

/// A resolved "where this file is going": the arr that will import it, and the
/// client + category it has to land in for that import to happen.
public struct DownloadDestination: Identifiable, Sendable, Hashable {
    public var id: String { "\(arr.rawValue)-\(client.id)" }
    public let arr: ServiceKind
    public let client: ArrDownloadClient
    /// The locally configured client we send through — same box the arr points
    /// at, but with the credentials the user gave *us*.
    public let serviceKind: ServiceKind
}

/// A download client that can be handed a new torrent/nzb, as opposed to only
/// reporting on the ones it already has (`DownloadProgressSource`).
public protocol DownloadAddSource: Sendable {
    func add(_ drop: DownloadDrop, category: String?, paused: Bool) async throws
    /// The client's own "add downloads paused" preference, so the sheet's
    /// checkbox starts on what the client would have done anyway. nil when the
    /// client has no such setting — the sheet then starts unchecked.
    func defaultAddPaused() async -> Bool?
}

public extension DownloadAddSource {
    func defaultAddPaused() async -> Bool? { nil }
}
