import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Rasterizes the bundled monochrome service icons (`ServiceIcons.xcassets`) into
/// base64 `data:` URIs the start page embeds as CSS masks — so an `<span>` can be
/// tinted any color (health-coloured) while reusing the exact same brand vectors
/// the app draws. Cached; prewarm on the main thread so the off-main HTTP handler
/// only ever reads strings.
public enum StartPageAssets {
    /// Every service that ships a brand icon (matches `ServiceIcons.xcassets`).
    public static let iconNames = [
        "radarr", "sonarr", "lidarr", "whisparr",
        "sabnzbd", "qbittorrent", "nzbget", "transmission", "deluge",
    ]

    private static let lock = NSLock()
    private static var cache: [String: String] = [:]  // "" caches a known miss

    /// Render the full icon set into the cache. Call once on the main thread.
    public static func prewarm() {
        for name in iconNames { _ = maskDataURI(name) }
    }

    /// A service icon as a `data:image/png;base64,…` URI for `mask-image`, or nil
    /// when no asset ships (→ the chip falls back to a plain dot).
    public static func maskDataURI(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit.isEmpty ? nil : hit }
        let uri = render(name, size: 44) ?? ""
        cache[name] = uri
        return uri.isEmpty ? nil : uri
    }

    #if canImport(AppKit)
    private static func render(_ name: String, size: CGFloat) -> String? {
        guard let image = Bundle.module.image(forResource: NSImage.Name(name)) else { return nil }
        let px = Int(size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
    #else
    private static func render(_ name: String, size: CGFloat) -> String? { nil }
    #endif
}
