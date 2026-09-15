import CryptoKit
import Foundation

/// Which family of download client can take a given payload. A `.torrent` file
/// and a magnet link both go to a torrent client; an `.nzb` only ever goes to a
/// usenet client. This is what filters the arrs offered in the add sheet — an
/// arr whose download client can't speak the payload's protocol isn't a choice,
/// it's a dead end.
nonisolated public enum DownloadKind: String, Sendable, CaseIterable {
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
nonisolated public struct DownloadDrop: Identifiable, Sendable, Equatable {
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

    /// The payload's BitTorrent v1 info-hash as lowercased hex, or nil when it
    /// can't be derived (an .nzb, a magnet without a `btih`, malformed bencode).
    ///
    /// This is the identity a torrent client files the download under, so it's
    /// what lets ArrBarr ask "do you already have this?" — needed for
    /// qBittorrent ≤ 5.1, whose add endpoint reports a duplicate with the same
    /// bare "Fails." as a genuinely broken file.
    public var torrentInfoHash: String? {
        switch content {
        case .magnet(let link): return Self.magnetInfoHash(link)
        case .file(let data, _): return Self.fileInfoHash(data)
        }
    }

    /// `xt=urn:btih:<hash>` — hex (40 chars) as-is, base32 (32 chars) decoded.
    private static func magnetInfoHash(_ link: String) -> String? {
        guard let items = URLComponents(string: link)?.queryItems else { return nil }
        for item in items where item.name == "xt" {
            guard let value = item.value?.trimmingCharacters(in: .whitespaces),
                  value.lowercased().hasPrefix("urn:btih:") else { continue }
            let hash = String(value.dropFirst("urn:btih:".count))
            if hash.count == 40, hash.allSatisfy(\.isHexDigit) {
                return hash.lowercased()
            }
            if hash.count == 32, let bytes = base32Decode(hash), bytes.count == 20 {
                return bytes.map { String(format: "%02x", $0) }.joined()
            }
        }
        return nil
    }

    /// SHA-1 over the raw bytes of the top-level `info` value. Only a bencode
    /// *scanner* — the info dictionary must be hashed exactly as it appears on
    /// disk, so the value is located by walking the structure and never decoded.
    private static func fileInfoHash(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        var index = 0
        guard scanByte(bytes, &index, UInt8(ascii: "d")) else { return nil }
        while index < bytes.count, bytes[index] != UInt8(ascii: "e") {
            guard let key = scanString(bytes, &index) else { return nil }
            let valueStart = index
            guard scanValue(bytes, &index) else { return nil }
            if key == Array("info".utf8) {
                let digest = Insecure.SHA1.hash(data: Data(bytes[valueStart..<index]))
                return digest.map { String(format: "%02x", $0) }.joined()
            }
        }
        return nil
    }

    private static func scanByte(_ bytes: [UInt8], _ index: inout Int, _ expected: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == expected else { return false }
        index += 1
        return true
    }

    /// `<length>:<content>` — returns the content bytes and advances past them.
    private static func scanString(_ bytes: [UInt8], _ index: inout Int) -> [UInt8]? {
        var length = 0
        var sawDigit = false
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            // Cap far above any legitimate field so a corrupt length can't
            // overflow the arithmetic below.
            guard length < 1 << 30 else { return nil }
            length = length * 10 + Int(bytes[index] - 0x30)
            sawDigit = true
            index += 1
        }
        guard sawDigit, scanByte(bytes, &index, UInt8(ascii: ":")),
              index + length <= bytes.count else { return nil }
        defer { index += length }
        return Array(bytes[index..<(index + length)])
    }

    /// Skips one bencode value of any type, iteratively: `depth` counts the
    /// unclosed lists/dicts instead of recursing so a hostile file can't
    /// overflow the stack.
    private static func scanValue(_ bytes: [UInt8], _ index: inout Int) -> Bool {
        var depth = 0
        repeat {
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case UInt8(ascii: "i"):
                index += 1
                while index < bytes.count, bytes[index] != UInt8(ascii: "e") { index += 1 }
                guard scanByte(bytes, &index, UInt8(ascii: "e")) else { return false }
            case UInt8(ascii: "l"), UInt8(ascii: "d"):
                depth += 1
                index += 1
            case UInt8(ascii: "e"):
                guard depth > 0 else { return false }
                depth -= 1
                index += 1
            case 0x30...0x39:
                guard scanString(bytes, &index) != nil else { return false }
            default:
                return false
            }
        } while depth > 0
        return true
    }

    /// RFC 4648 base32 (no padding), as magnets spell v1 hashes.
    private static func base32Decode(_ text: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer = 0, bits = 0
        var out: [UInt8] = []
        for char in text.uppercased() {
            guard let value = alphabet.firstIndex(of: char) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return out
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
nonisolated public struct ArrDownloadClient: Identifiable, Sendable, Hashable {
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
nonisolated public struct DownloadDestination: Identifiable, Sendable, Hashable {
    public var id: String { "\(arr.rawValue)-\(client.id)" }
    public let arr: ServiceKind
    public let client: ArrDownloadClient
    /// The locally configured client we send through — same box the arr points
    /// at, but with the credentials the user gave *us*.
    public let serviceKind: ServiceKind
}

/// A download client that can be handed a new torrent/nzb, as opposed to only
/// reporting on the ones it already has (`DownloadProgressSource`).
nonisolated public protocol DownloadAddSource: Sendable {
    func add(_ drop: DownloadDrop, category: String?, paused: Bool) async throws
    /// The client's own "add downloads paused" preference, so the sheet's
    /// checkbox starts on what the client would have done anyway. nil when the
    /// client has no such setting — the sheet then starts unchecked.
    func defaultAddPaused() async -> Bool?
}

nonisolated public extension DownloadAddSource {
    func defaultAddPaused() async -> Bool? { nil }
}
