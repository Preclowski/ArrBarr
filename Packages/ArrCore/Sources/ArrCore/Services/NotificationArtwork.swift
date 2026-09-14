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

/// The thumbnail a queue notification carries.
///
/// This exists so the banner can stop *spelling* which arr the event came from.
/// The arr's name was taking a whole line of a three-line banner to say
/// something a picture says instantly — and the picture it can say it with is
/// the poster of the thing being downloaded, which is far more useful than the
/// service name anyway.
///
/// Two tiers, in order:
///  1. The title's own poster.
///  2. The arr's mark on its brand colour — different per service, so a Radarr
///     grab and a Lidarr grab are still tellable apart at a glance.
///
/// The poster is fetched rather than only read from cache, but it never gets
/// to hold the banner hostage. `prefetch` starts the download the moment the
/// coalescer first hears about an item — which for an episodic arr is a whole
/// grouping window (5 s) before the banner is due — and `attachment` then waits
/// only `waitBudget` for that in-flight fetch to land. Whatever arrives late
/// still ends up on disk, so the next grab for the same title is instant; the
/// banner it missed simply carries the mark.
@MainActor
enum NotificationArtwork {
    /// How long a banner may wait on artwork that hasn't arrived yet.
    ///
    /// Under the 5 s episodic hold, so a series grab that started its fetch at
    /// `enqueue` is never delayed by this at all — the wait is real only for
    /// the leading-edge arrs (Radarr, Lidarr), whose banner fires the instant
    /// the grab is seen. Four seconds of "no poster yet" is worth spending
    /// there: the notification still reads as just-now, and the alternative is
    /// a mark on every first-time title.
    private static let waitBudget: TimeInterval = 4
    /// Longest edge of the generated brand tile. 256 px covers the banner
    /// thumbnail at @2x with room to spare, and the tile is drawn once per
    /// service per launch.
    private static let tileSize = 256

    /// Rendered brand tiles, keyed by service. The PNG bytes are reused; the
    /// *file* is not, because `UNUserNotificationCenter` takes ownership of an
    /// attachment's file and moves it into its own store.
    private static var tileCache: [QueueItem.Source: Data] = [:]

    /// Posters currently being downloaded for a pending banner, so the same
    /// artwork is never requested twice.
    private static var inFlight: Set<URL> = []

    /// Start pulling this item's poster now. Called when the coalescer first
    /// sees a grab, which is the earliest moment we know a banner is coming —
    /// and for an episodic arr, a full grouping window before it is due.
    ///
    /// Safe to call repeatedly for the same title: a cached poster starts
    /// nothing, and a download already running is not started twice.
    static func prefetch(_ item: QueueItem, apiKey: String?) {
        guard let url = item.posterURL else { return }
        startFetch(url, apiKey: apiKey)
    }

    /// Attachment for one queue item — its poster if we have it or can get it
    /// inside `waitBudget`, else the arr's mark.
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

    /// Attachment for something that isn't one title — a mixed batch, an arr
    /// health problem. Always the service mark.
    static func attachment(for source: QueueItem.Source) -> UNNotificationAttachment? {
        markAttachment(for: source)
    }

    // MARK: - Poster

    /// `.icon` first: it is the durable tier the library index keeps warm, so
    /// it is the one that is actually populated when a grab lands for a title
    /// the user has never opened. `.card` is the consolation prize from having
    /// browsed the title's detail view.
    private static func cachedPoster(_ url: URL) -> Data? {
        PosterStore.storedData(for: url, tier: .icon)
            ?? PosterStore.storedData(for: url, tier: .card)
    }

    /// Give the download until the budget runs out, then give up on it.
    ///
    /// Watches the *cache* rather than awaiting the fetch task, and that is the
    /// point: running out of budget must abandon the wait without abandoning
    /// the download. A poster that lands a second too late still lands on disk,
    /// so the next grab for that title has it instantly — where cancelling the
    /// fetch would leave the title without artwork forever.
    private static func awaitPoster(_ url: URL, apiKey: String?) async -> Data? {
        startFetch(url, apiKey: apiKey)
        let deadline = Date().addingTimeInterval(waitBudget)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let data = cachedPoster(url) { return data }
            // The fetch finished without producing anything — a 404 on the
            // arr's MediaCover, a poster the title simply doesn't have. No
            // point sitting out the rest of the budget for it.
            if !inFlight.contains(url) { return nil }
        }
        return nil
    }

    private static func posterAttachment(_ data: Data) -> UNNotificationAttachment? {
        guard let file = writeTemp(data, ext: "jpg") else { return nil }
        // A poster is 2:3 and the banner thumbnail is square, so without a
        // clipping rect the system picks the crop for us. Centred rather than
        // top-anchored on purpose: Apple documents this rect as "the unit
        // coordinate space" without saying which corner the origin is in, and
        // a vertically centred window is the same rectangle under either
        // reading. An off-centre crop would land upside down half the time.
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

    /// The arr's own mark, knocked out of its brand colour.
    ///
    /// The marks in `ServiceIcons.xcassets` are template cuts — one black path
    /// on transparency — so they are used here as a *mask* rather than drawn:
    /// clip to the mark, fill with ink. That also means the ink can follow the
    /// background instead of being fixed white, which matters because two of
    /// the four brand colours are light enough that white on them is unreadable.
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

    /// The service mark from `ServiceIcons.xcassets`, rasterised at `side`.
    ///
    /// nil under `swift test` and that is expected: SwiftPM copies the asset
    /// catalog into the bundle without compiling it, so no asset name resolves
    /// outside an Xcode build. The caller degrades to a plain brand-coloured
    /// tile rather than to no attachment.
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

    /// Each arr's accent, taken from its own web UI. Approximations of somebody
    /// else's brand rather than exact values — worth correcting if any of them
    /// looks off next to the real thing.
    private static func brandColor(for source: QueueItem.Source) -> CGColor {
        switch source {
        case .radarr:   return rgb(0xFF, 0xC2, 0x30)
        case .sonarr:   return rgb(0x35, 0xC5, 0xF4)
        case .lidarr:   return rgb(0x15, 0x95, 0x52)
        case .whisparr: return rgb(0xF0, 0x5A, 0x9E)
        }
    }

    /// Near-black on a light brand colour, white on a dark one. Radarr's yellow
    /// and Sonarr's cyan are both far too light to carry white type.
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

    /// A throwaway copy for the notification centre to take. It moves the file
    /// into its own attachment store on `add()`, so each notification needs its
    /// own — handing it the cache's file would empty the cache.
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
