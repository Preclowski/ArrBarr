import Foundation

/// Filters the arrs offered in the add sheet: an arr whose client can't speak the protocol is a dead end.
nonisolated public enum DownloadKind: String, Sendable, CaseIterable {
    case torrent
    case usenet

    /// Sonarr/Radarr/Whisparr (v3) send `"torrent"`/`"usenet"`, Lidarr (v1) sends the enum name
    /// (`"TorrentDownloadProtocol"`); an exact match drops every Lidarr client.
    init?(arrProtocol raw: String) {
        let value = raw.lowercased()
        if value.contains("torrent") { self = .torrent }
        else if value.contains("usenet") || value.contains("nzb") { self = .usenet }
        else { return nil }
    }
}

/// Carries its own display name so the UI never re-derives one from a URL it no longer holds.
nonisolated public struct DownloadDrop: Identifiable, Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case file(Data, filename: String)
        case magnet(String)
    }

    public let id: UUID
    public let content: Content
    public let kind: DownloadKind
    /// The file name, or a magnet's `dn` parameter.
    public let displayName: String

    public init(id: UUID = UUID(), content: Content, kind: DownloadKind, displayName: String) {
        self.id = id
        self.content = content
        self.kind = kind
        self.displayName = displayName
    }

    /// Nil for a URL no client can take. Reads the file here: a dropped URL's security scope doesn't outlive the drop handler.
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
        // `startAccessing…` returns false for URLs that don't need a scope — not a failure, so read anyway.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        self.init(content: .file(data, filename: url.lastPathComponent), kind: kind, displayName: url.lastPathComponent)
    }

    /// Absent on hash-only magnets, so callers fall back to the raw link.
    private static func magnetName(_ url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        // URLComponents leaves `+` literal, but trackers form-encode `dn`, where it means a space.
        let raw = items.first { $0.name == "dn" }?.value?
            .replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (raw?.isEmpty == false) ? raw : nil
    }
}

/// The category is the point: a file added under `tv-sonarr` gets imported; with no category it's orphaned.
nonisolated public struct ArrDropClient: Identifiable, Sendable, Hashable {
    public let id: Int
    public let name: String
    /// Mapped to our `ServiceKind` by `serviceKind`, which finds the credentials to talk to it.
    public let implementation: String
    public let kind: DownloadKind
    public let category: String?

    /// Nil for clients ArrBarr doesn't support (Flood, Hadouken, …), which are filtered out of the picker.
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

nonisolated public struct DownloadDestination: Identifiable, Sendable, Hashable {
    public var id: String { "\(arr.rawValue)-\(client.id)" }
    public let arr: ServiceKind
    public let client: ArrDropClient
    /// Same box the arr points at, with the credentials the user gave us.
    public let serviceKind: ServiceKind
}

nonisolated protocol DownloadAddSource: Sendable {
    func add(_ drop: DownloadDrop, category: String?, paused: Bool) async throws
    /// Seeds the sheet's checkbox; nil when the client has no such setting.
    func defaultAddPaused() async -> Bool?
}

nonisolated extension DownloadAddSource {
    func defaultAddPaused() async -> Bool? { nil }
}
