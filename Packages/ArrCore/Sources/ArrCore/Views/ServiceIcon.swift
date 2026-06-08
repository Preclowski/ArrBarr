import SwiftUI

public extension QueueItem.Source {
    /// Brand icon asset in `ServiceIcons.xcassets`. Every arr ships one, so
    /// this is always non-nil (matches the enum's raw value).
    var brandIconName: String { rawValue }
}

public extension ServiceKind {
    /// Brand icon asset name in `ServiceIcons.xcassets`, or `nil` when none
    /// ships (→ SF Symbol fallback). Only rTorrent currently lacks one.
    var brandIconName: String? {
        switch self {
        case .radarr, .sonarr, .lidarr, .whisparr, .sabnzbd,
             .qbittorrent, .nzbget, .transmission, .deluge:
            return rawValue
        case .rtorrent:
            return nil
        }
    }

    /// SF Symbol used when no brand asset ships (only rTorrent today).
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

/// A service's brand icon: a monochrome vector (tinted by the inherited
/// foreground style, so it adapts to light/dark automatically) sized at a
/// point size that tracks the user's font-scale preset — exactly like the
/// `.scaledFont` SF Symbols it replaces. Falls back to an SF Symbol when no
/// brand asset ships for the service.
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

    public init(kind: ServiceKind, fallbackSymbol: String, size: CGFloat) {
        self.brandName = kind.brandIconName
        self.fallbackSymbol = fallbackSymbol
        self.size = size
    }

    public init(kind: ServiceKind, size: CGFloat) {
        self.brandName = kind.brandIconName
        self.fallbackSymbol = kind.symbol
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
