import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ArrCore

/// The pure halves of the poster pipeline: which URL we ask the CDN for, how
/// artwork is downscaled, and what a cached image is charged in memory.
@Suite("Poster thumbnails")
struct PosterThumbnailTests {

    // MARK: - Source-size negotiation

    @Test("TMDB posters are fetched at w185, not original")
    func tmdbVariant() throws {
        let original = URL(string: "https://image.tmdb.org/t/p/original/2U0oAVAE0lDRhNmJPPYhDW9kQ8t.jpg")!
        let small = try #require(PosterStore.sourceURL(for: original, tier: .icon))
        #expect(small.absoluteString == "https://image.tmdb.org/t/p/w185/2U0oAVAE0lDRhNmJPPYhDW9kQ8t.jpg")
    }

    @Test("A TMDB URL that is already small is left alone")
    func tmdbAlreadySmall() {
        let small = URL(string: "https://image.tmdb.org/t/p/w185/abc.jpg")!
        #expect(PosterStore.sourceURL(for: small, tier: .icon) == nil)
    }

    @Test("TheTVDB artwork gets the _t thumbnail suffix")
    func tvdbVariant() throws {
        let full = URL(string: "https://artworks.thetvdb.com/banners/v4/series/393187/posters/643a36c1290ca.jpg")!
        let small = try #require(PosterStore.sourceURL(for: full, tier: .icon))
        #expect(small.absoluteString
            == "https://artworks.thetvdb.com/banners/v4/series/393187/posters/643a36c1290ca_t.jpg")
        // Idempotent — a suffixed URL must not become `_t_t`.
        #expect(PosterStore.sourceURL(for: small, tier: .icon) == nil)
    }

    /// An arr's own cover path has no variant convention we can rely on, so it
    /// must be fetched verbatim rather than guessed at.
    @Test("Unknown hosts are fetched as-is")
    func unknownHostUntouched() {
        let mediaCover = URL(string: "http://192.168.1.10:7878/MediaCover/42/poster.jpg")!
        #expect(PosterStore.sourceURL(for: mediaCover, tier: .icon) == nil)
        #expect(PosterStore.sourceURL(for: URL(string: "https://example.com/a.jpg")!, tier: .icon) == nil)
    }

    @Test("Card and icon ask the CDN for different sizes")
    func tierPicksItsOwnVariant() throws {
        let original = URL(string: "https://image.tmdb.org/t/p/original/abc.jpg")!
        let icon = try #require(PosterStore.sourceURL(for: original, tier: .icon))
        let card = try #require(PosterStore.sourceURL(for: original, tier: .card))
        #expect(icon.path.contains("/w185/"))
        #expect(card.path.contains("/w780/"))
        // An `original` URL is already what the lightbox wants, so asking for
        // `original` is a no-op rewrite.
        #expect(PosterStore.sourceURL(for: original, tier: .full) == nil)
        // TheTVDB's `_t` is a thumbnail — fine for an icon, too small to stand
        // in for a card, so a card must fall through to the full-size URL.
        let tvdb = URL(string: "https://artworks.thetvdb.com/banners/v4/series/1/posters/x.jpg")!
        #expect(PosterStore.sourceURL(for: tvdb, tier: .card) == nil)
    }

    @Test("The lightbox upgrades a small variant to the original")
    func lightboxUpgradesToOriginal() throws {
        // TMDB person portraits are built at w185 (`TMDBClient.profileURL`),
        // and the lightbox zooms to 5×: without the upgrade, tapping a
        // portrait enlarged a 185-pixel image.
        let portrait = URL(string: "https://image.tmdb.org/t/p/w185/face.jpg")!
        let full = try #require(PosterStore.sourceURL(for: portrait, tier: .full))
        #expect(full.path.contains("/original/"))
    }

    // MARK: - Retention policy
    //
    // The icon store is what a Spotlight re-index re-attaches artwork from, so
    // it must never be reclaimed on the card store's schedule. Retention lives
    // on the tier (rather than being passed in) exactly so this can be pinned.

    @Test("The icon tier outlives the card tier by a wide margin")
    func retentionOrdering() throws {
        let icon = try #require(PosterTier.icon.retention)
        let card = try #require(PosterTier.card.retention)
        #expect(icon > card)
        #expect(icon >= 90 * 24 * 3600)
    }

    /// Both the progressive placeholder ("show the biggest smaller copy we
    /// have") and derive-from-larger ("resize locally instead of downloading")
    /// pick a tier by this ordering, in opposite directions.
    @Test("Tiers are ordered by size")
    func tierOrdering() {
        #expect(PosterTier.icon.rank < PosterTier.card.rank)
        #expect(PosterTier.card.rank < PosterTier.full.rank)
        // Ranks must agree with the pixel caps, or a "smaller" copy could be
        // the bigger file.
        #expect(PosterTier.icon.maxPixelSize! < PosterTier.card.maxPixelSize!)
    }

    @Test("The lightbox tier is never written to disk")
    func fullTierIsMemoryOnly() {
        #expect(PosterTier.full.directoryName == nil)
        #expect(PosterTier.full.retention == nil)
        #expect(PosterTier.full.maxPixelSize == nil)
        // Each stored tier gets its own directory, or they would overwrite
        // each other's copies of the same poster.
        let dirs = PosterTier.allCases.compactMap(\.directoryName)
        #expect(Set(dirs).count == dirs.count)
    }

    // MARK: - Downscaling

    @Test("Downscaling caps the long edge and keeps the aspect ratio",
          arguments: [CGSize(width: 2000, height: 3000), CGSize(width: 1200, height: 1200)])
    func downscaleKeepsAspect(source: CGSize) throws {
        let data = try #require(Self.solidImage(size: source, hasAlpha: false))
        let thumb = try #require(PosterStore.resized(data, maxPixelSize: 256))
        let out = try #require(Self.dimensions(of: thumb))
        #expect(max(out.width, out.height) == 256)
        // Same aspect ratio as the source, within a pixel of rounding.
        #expect(abs(out.width / out.height - source.width / source.height) < 0.01)
    }

    /// The tier caps exist to bound sources with no variant convention. For the
    /// CDN variant we actually asked for, re-encoding would cost CPU and a
    /// generation of quality for nothing — so 185×278 (TMDB's `w185`) and
    /// 780×1170 (`w780`) have to pass straight through their tier.
    @Test("The CDN variant a tier asks for is stored untouched",
          arguments: [(CGSize(width: 185, height: 278), PosterTier.icon),
                      (CGSize(width: 780, height: 1170), PosterTier.card)])
    func cdnVariantIsNotReencoded(source: CGSize, tier: PosterTier) throws {
        let data = try #require(Self.solidImage(size: source, hasAlpha: false))
        #expect(PosterStore.resized(data, maxPixelSize: tier.maxPixelSize) == data)
        // …and the lightbox tier (no cap) always passes through.
        #expect(PosterStore.resized(data, maxPixelSize: PosterTier.full.maxPixelSize) == data)
    }

    /// Some artwork ships as RGBA PNG; encoding that to JPEG would flatten the
    /// transparency to black, which reads as a broken poster in Spotlight.
    @Test("Artwork with alpha keeps its alpha")
    func alphaSurvives() throws {
        let data = try #require(Self.solidImage(size: CGSize(width: 600, height: 900), hasAlpha: true))
        let thumb = try #require(PosterStore.resized(data, maxPixelSize: 256))
        let src = try #require(CGImageSourceCreateWithData(thumb as CFData, nil))
        #expect(CGImageSourceGetType(src) as String? == UTType.png.identifier)
    }

    // MARK: - Memory accounting

    /// The cache holds decoded bitmaps but used to charge the *compressed*
    /// size, which under-counts by 20-50× and let a "50 MB" limit hold roughly
    /// a gigabyte.
    @Test("Cached images are charged their decoded size")
    func decodedCost() throws {
        let data = try #require(Self.solidImage(size: CGSize(width: 200, height: 300), hasAlpha: false))
        let image = try #require(PlatformImage(data: data))
        #expect(PosterStore.decodedByteCost(image) == 200 * 300 * 4)
    }

    // MARK: - Helpers

    private static func solidImage(size: CGSize, hasAlpha: Bool) -> Data? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: hasAlpha ? 0.5 : 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func dimensions(of data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return CGSize(width: w, height: h)
    }
}
