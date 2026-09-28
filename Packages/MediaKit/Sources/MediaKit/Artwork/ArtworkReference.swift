import Foundation

public enum ArtworkTier: String, Sendable, Codable, CaseIterable {
    case icon, card, full
    public var pixels: Int? { switch self { case .icon: 256; case .card: 780; case .full: nil } }
}

/// The single thing a poster layer consumes; structurally unable to carry a token.
public struct ArtworkReference: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case poster, fanart, banner, thumbnail, still, profile }
    public enum HeaderRef: Hashable, Sendable, Codable { case literal(String), credential(InstanceID) }
    public enum Sizing: Hashable, Sendable, Codable {
        case native
        case tmdbCDN(path: String)
        case plexTranscode(photoPath: String)
        case jellyfinFill(itemID: String, tag: String?)
    }

    public let url: URL
    public let headers: [String: HeaderRef]
    public let sizing: Sizing
    public let kind: Kind

    public init(url: URL, headers: [String: HeaderRef] = [:], sizing: Sizing = .native, kind: Kind) {
        self.url = url; self.headers = headers; self.sizing = sizing; self.kind = kind
    }

    public func sized(_ tier: ArtworkTier) -> ArtworkReference {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return self }
        if case let .tmdbCDN(path) = sizing {
            // TMDB's own widths nearest each tier (w185 ≈ 13 kB, w780 ≈ 161 kB vs 241 kB for the original).
            let width = switch tier { case .icon: "w185"; case .card: "w780"; case .full: "original" }
            c.path = "/t/p/\(width)\(path.hasPrefix("/") ? path : "/" + path)"
            return ArtworkReference(url: c.url ?? url, headers: headers, sizing: sizing, kind: kind)
        }
        guard let pixels = tier.pixels else { return self }
        switch sizing {
        case .native, .tmdbCDN:
            return self
        case let .plexTranscode(photoPath):
            c.path = "/photo/:/transcode"
            c.queryItems = [URLQueryItem(name: "width", value: String(pixels)), URLQueryItem(name: "height", value: String(pixels * 3 / 2)),
                            URLQueryItem(name: "minSize", value: "1"), URLQueryItem(name: "upscale", value: "0"), URLQueryItem(name: "url", value: photoPath)]
        case let .jellyfinFill(_, tag):
            // The url already names the item's image; rewriting the path would drop a reverse-proxy prefix.
            c.queryItems = [URLQueryItem(name: "maxWidth", value: String(pixels))] + (tag.map { [URLQueryItem(name: "tag", value: $0)] } ?? [])
        }
        return ArtworkReference(url: c.url ?? url, headers: headers, sizing: sizing, kind: kind)
    }

    public var cacheKey: String { "\(kind.rawValue)|\(sizingKey)|\(url.absoluteString)" }

    private var sizingKey: String {
        switch sizing {
        case .native: "native"
        case let .tmdbCDN(p): "tmdb:\(p)"
        case let .plexTranscode(p): "plex:\(p)"
        case let .jellyfinFill(id, tag): "jf:\(id):\(tag ?? "")"
        }
    }
}
