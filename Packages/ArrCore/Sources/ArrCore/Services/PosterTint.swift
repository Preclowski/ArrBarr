import SwiftUI
import CoreGraphics

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Average colour of a poster's bottom third, the wash under the Quiz card's panel. Derived from pixels
/// because `.regularMaterial` backdrop sampling arrives frames after the card and can't be animated.
enum PosterTint {
    /// Posters are immutable per URL and the deck revisits cards, so no eviction.
    private static var cache: [String: Color] = [:]

    private static let sampledHeightFraction: CGFloat = 0.33

    /// Uses the `.card` tier the deck displays, so the tint shares the card's fetch; another tier meant
    /// a separate download and a tint arriving seconds late.
    static func color(for url: URL?) async -> Color? {
        guard let url else { return nil }
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        var image = await PosterStore.shared.cachedPreview(for: url, below: .full)
        if image == nil {
            image = await PosterStore.shared.image(for: url, tier: .card)
        }
        guard let image, let color = averageColor(of: image) else { return nil }
        cache[key] = color
        return color
    }

    /// Drawing into a 1×1 context box-filters the region, so the one pixel is the mean.
    static func averageColor(of image: PlatformImage) -> Color? {
        guard let cgImage = image.tintSourceCGImage else { return nil }
        let fullHeight = CGFloat(cgImage.height)
        let sliceHeight = max(1, (fullHeight * sampledHeightFraction).rounded())
        // CGImage coordinates put the origin top-left.
        let cropRect = CGRect(x: 0, y: fullHeight - sliceHeight,
                              width: CGFloat(cgImage.width), height: sliceHeight)
        guard let slice = cgImage.cropping(to: cropRect) else { return nil }

        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(slice, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        // A fully transparent sample means no tint, not a deliberate black wash.
        guard pixel[3] > 0 else { return nil }
        return Color(
            .sRGB,
            red: Double(pixel[0]) / 255,
            green: Double(pixel[1]) / 255,
            blue: Double(pixel[2]) / 255,
            opacity: 1
        )
    }

    /// Public for `AppCaches.clearArtwork()`: keyed by poster URL, these would outlive their images.
    static func resetCache() { cache.removeAll() }
}

extension PlatformImage {
    /// NSImage is a container of representations, so resolve one for its own size.
    var tintSourceCGImage: CGImage? {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }
}
