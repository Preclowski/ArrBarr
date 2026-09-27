import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Queue notification thumbnail: the title's poster, else the arr's mark on its brand colour.
/// `prefetch` starts the fetch early; `attachment` waits at most `waitBudget`, and late posters still land on disk.
enum NotificationArtwork {
    /// Under the 5 s episodic hold, so it only delays leading-edge arrs (Radarr, Lidarr),
    /// where a few seconds beats a mark on every first-time title.
    private static let waitBudget: TimeInterval = 4
    /// Covers the banner thumbnail at @2x; drawn once per service per launch.
    private static let tileSize = 256

    /// Bytes are reused, files are not: `UNUserNotificationCenter` moves an attachment's file into its own store.
    private static var tileCache: [QueueItem.Source: Data] = [:]

    private static var inFlight: Set<URL> = []

    /// For an episodic arr this runs a full grouping window before the banner is due. Idempotent.
    static func prefetch(_ item: QueueItem, apiKey: String?) {
        guard let url = item.posterURL else { return }
        startFetch(url, apiKey: apiKey)
    }

    static func attachment(for item: QueueItem, apiKey: String?) async -> UNNotificationAttachment? {
        if let url = item.posterURL {
            var data = cachedPoster(url)
            if data == nil { data = await awaitPoster(url, apiKey: apiKey) }
            if let data, let attachment = posterAttachment(data) { return attachment }
        }
        return markAttachment(for: item.source)
    }

    private static func startFetch(_ url: URL, apiKey: String?) {
        guard cachedPoster(url) == nil, !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task { @MainActor in
            _ = await PosterStore.shared.fetchStoring(url, tier: .icon, apiKey: apiKey)
            inFlight.remove(url)
        }
    }

    static func attachment(for source: QueueItem.Source) -> UNNotificationAttachment? {
        markAttachment(for: source)
    }

    // MARK: - Poster

    /// `.icon` first: the library index keeps it warm, so it exists for titles never opened.
    private static func cachedPoster(_ url: URL) -> Data? {
        PosterStore.storedData(for: url, tier: .icon)
            ?? PosterStore.storedData(for: url, tier: .card)
    }

    /// Polls the cache instead of awaiting the fetch, so giving up on the wait doesn't cancel
    /// the download and the next grab for the title has its poster.
    private static func awaitPoster(_ url: URL, apiKey: String?) async -> Data? {
        startFetch(url, apiKey: apiKey)
        let deadline = Date().addingTimeInterval(waitBudget)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let data = cachedPoster(url) { return data }
            // The fetch ended with nothing (e.g. a MediaCover 404); don't sit out the budget.
            if !inFlight.contains(url) { return nil }
        }
        return nil
    }

    private static func posterAttachment(_ data: Data) -> UNNotificationAttachment? {
        guard let file = writeTemp(data, ext: "jpg") else { return nil }
        // Centred crop of the 2:3 poster for the square thumbnail: Apple doesn't document the
        // rect's origin corner, and a centred window is the same under either reading.
        let crop = CGRect(x: 0, y: 1.0 / 6.0, width: 1, height: 2.0 / 3.0)
        let options: [String: Any] = [
            UNNotificationAttachmentOptionsThumbnailClippingRectKey:
                CGRectCreateDictionaryRepresentation(crop),
        ]
        return try? UNNotificationAttachment(
            identifier: "", url: file, options: options)
    }

    // MARK: - Service mark

    private static func markAttachment(for source: QueueItem.Source) -> UNNotificationAttachment? {
        let data: Data
        if let cached = tileCache[source] {
            data = cached
        } else {
            guard let rendered = renderTile(for: source) else { return nil }
            tileCache[source] = rendered
            data = rendered
        }
        guard let file = writeTemp(data, ext: "png") else { return nil }
        return try? UNNotificationAttachment(identifier: "", url: file, options: nil)
    }

    /// The template marks are used as a mask so the ink can follow the background:
    /// white is unreadable on two of the brand colours.
    private static func renderTile(for source: QueueItem.Source) -> Data? {
        let side = tileSize
        guard let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let full = CGRect(x: 0, y: 0, width: side, height: side)
        let brand = brandColor(for: source)
        context.setFillColor(brand)
        context.fill(full)

        if let mark = markImage(named: source.rawValue, side: side) {
            let inset = CGFloat(side) * 0.26
            let markRect = full.insetBy(dx: inset, dy: inset)
            context.saveGState()
            context.clip(to: markRect, mask: mark)
            context.setFillColor(inkColor(on: brand))
            context.fill(markRect)
            context.restoreGState()
        }

        guard let image = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// nil when the asset doesn't resolve; the caller falls back to a plain brand-coloured tile.
    private static func markImage(named name: String, side: Int) -> CGImage? {
        #if os(macOS)
        guard let image = Bundle.module.image(forResource: name)?.copy() as? NSImage
        else { return nil }
        image.size = NSSize(width: side, height: side)
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        guard let image = UIImage(named: name, in: .module, with: nil) else { return nil }
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let raster = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return raster.cgImage
        #endif
    }

    /// Approximated from each arr's web UI.
    private static func brandColor(for source: QueueItem.Source) -> CGColor {
        switch source {
        case .radarr:   return rgb(0xFF, 0xC2, 0x30)
        case .sonarr:   return rgb(0x35, 0xC5, 0xF4)
        case .lidarr:   return rgb(0x15, 0x95, 0x52)
        case .whisparr: return rgb(0xF0, 0x5A, 0x9E)
        }
    }

    /// Radarr's yellow and Sonarr's cyan are too light to carry white.
    private static func inkColor(on background: CGColor) -> CGColor {
        let c = background.components ?? [0, 0, 0, 1]
        guard c.count >= 3 else { return rgb(0xFF, 0xFF, 0xFF) }
        let luminance = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        return luminance > 0.6 ? rgb(0x1C, 0x1C, 0x1E) : rgb(0xFF, 0xFF, 0xFF)
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
        CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255, alpha: 1)
    }

    // MARK: - Files

    /// Each notification needs its own copy: `add()` moves the file into the attachment store.
    private static func writeTemp(_ data: Data, ext: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: file)
            return file
        } catch {
            return nil
        }
    }
}
