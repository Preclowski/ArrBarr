import SwiftUI

public extension QueueItem.Source {
    var brandIconName: String { rawValue }
}

public extension ServiceKind {
    /// `nil` → SF Symbol fallback (only rTorrent today).
    var brandIconName: String? {
        switch self {
        case .radarr, .sonarr, .lidarr, .whisparr, .sabnzbd,
             .qbittorrent, .nzbget, .transmission, .deluge:
            return rawValue
        case .rtorrent:
            return nil
        }
    }

    var symbol: String {
        switch self {
        case .radarr: return "film"
        case .sonarr: return "tv"
        case .lidarr: return "music.note"
        case .whisparr: return "flame"
        case .sabnzbd, .nzbget: return "doc.zipper"
        case .qbittorrent, .transmission, .rtorrent, .deluge: return "arrow.triangle.2.circlepath"
        }
    }
}

public extension MediaServerKind {
    var brandIconName: String { rawValue }
}

/// Monochrome, tinted by the foreground style, sized by the font-scale preset.
public struct ServiceIcon: View {
    @Environment(\.fontScale) private var scale
    private let brandName: String?
    private let fallbackSymbol: String
    private let size: CGFloat

    public init(source: QueueItem.Source, size: CGFloat) {
        self.brandName = source.brandIconName
        self.fallbackSymbol = source.symbol
        self.size = size
    }

    public init(kind: ServiceKind, size: CGFloat) {
        self.brandName = kind.brandIconName
        self.fallbackSymbol = kind.symbol
        self.size = size
    }

    public init(mediaServer kind: MediaServerKind, size: CGFloat) {
        self.brandName = kind.brandIconName
        self.fallbackSymbol = "play.tv"
        self.size = size
    }

    /// Prowlarr has no `ServiceKind`. The asset is selfh.st's monochrome line art,
    /// so it tints like every other mark.
    public init(prowlarr size: CGFloat) {
        self.brandName = "prowlarr"
        self.fallbackSymbol = "magnifyingglass.circle"
        self.size = size
    }

    public var body: some View {
        if let brandName {
            Image(brandName, bundle: .module)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * scale, height: size * scale)
        } else {
            Image(systemName: fallbackSymbol).scaledFont(size: size)
        }
    }
}

