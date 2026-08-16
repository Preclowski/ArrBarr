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

public extension MediaServerKind {
    /// Brand icon asset in `ServiceIcons.xcassets`. All three ship one, so
    /// unlike `ServiceKind` this is never nil.
    var brandIconName: String { rawValue }
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

/// A brand mark for use **inside a `Menu`'s rows**.
///
/// `ServiceIcon` is the right thing everywhere else and would be wrong here:
/// a macOS menu row is an AppKit menu item, so SwiftUI hands the `Image`
/// straight to AppKit, which draws it at the NSImage's own size and ignores
/// the `.resizable().frame(…)` the view asked for. These assets are 512-point
/// vectors — which is how a sort menu ended up with logos the height of the
/// screen. So the resize happens on the *image*, before SwiftUI sees it.
struct MenuBrandIcon: View {
    let asset: String
    var side: CGFloat = 14
    /// Tint like an SF Symbol instead of drawing the artwork's own colours.
    /// The arr marks and the `rating-*-mono` marks are single-path
    /// silhouettes and template cleanly; the full-colour `rating-*` artwork
    /// does not — IMDb's is a filled plaque with the letters drawn on top, so
    /// its silhouette is a solid blob.
    var template: Bool

    var body: some View {
        if let image = Self.sized(asset, side: side, template: template) {
            Image(platformImage: image)
        } else {
            // An asset that didn't resolve draws nothing rather than an
            // oversized fallback.
            Color.clear.frame(width: side, height: side)
        }
    }

    private static func sized(_ asset: String, side: CGFloat, template: Bool) -> PlatformImage? {
        #if os(macOS)
        guard let original = Bundle.module.image(forResource: asset),
              let copy = original.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: side, height: side)
        copy.isTemplate = template
        return copy
        #else
        guard let original = UIImage(named: asset, in: .module, with: nil) else { return nil }
        let box = CGSize(width: side, height: side)
        let scaled = UIGraphicsImageRenderer(size: box).image { _ in
            original.draw(in: CGRect(origin: .zero, size: box))
        }
        return template ? scaled.withRenderingMode(.alwaysTemplate) : scaled
        #endif
    }
}
