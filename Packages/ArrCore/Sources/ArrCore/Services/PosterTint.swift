import SwiftUI
import CoreGraphics

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Average colour of a poster's lower edge — the wash under the Quiz card's
/// metadata panel.
///
/// That panel used to get its colour purely from `.regularMaterial` sampling
/// whatever happened to be behind it. Backdrop sampling is a rendering-time
/// side effect: it follows sibling cards in the ZStack, it settles a frame or
/// more after a transform animation, and nothing in our code can animate it.
/// The result was a colour that visibly arrived *after* the card it belonged
/// to. Deriving the colour from the poster's own pixels makes it a value we
/// own — available before the card is promoted to the top of the deck, and
/// animatable like any other.
///
/// The bottom third is what's sampled, not the whole image: that's the region
/// the panel actually covers, and a poster's sky or title treatment up top is
/// frequently nothing like the colour at its feet.
@MainActor
public enum PosterTint {
    /// Keyed by absolute URL. Posters are immutable at a given URL and the
    /// deck revisits cards (peek → top), so this is a small dictionary that
    /// saves a decode per revisit rather than a real cache with eviction.
    private static var cache: [String: Color] = [:]

    /// Fraction of the image height sampled, measured from the bottom.
    private static let sampledHeightFraction: CGFloat = 0.33

    /// Poster tint for `url`, or nil when there's no artwork to sample.
    ///
    /// Takes whatever copy is already on hand first, and only then asks for
    /// the `.card` tier — the exact tier the deck itself displays. Asking for
    /// a *different* tier (the small `.icon` one seemed thriftier) meant a
    /// separate download on any poster whose icon copy wasn't cached, so the
    /// tint arrived seconds after the artwork it was supposed to match. A 1×1
    /// average is no more accurate from a smaller source anyway; sharing the
    /// card's own fetch is what makes the colour land *with* the card.
    public static func color(for url: URL?) async -> Color? {
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

    /// Averages the bottom slice of `image` down to a single pixel.
    ///
    /// Drawing into a 1×1 context is the cheap way to do this: CoreGraphics
    /// box-filters the whole region on the way down, so the one pixel that
    /// lands is the mean. No CoreImage context to spin up, and it behaves the
    /// same on both platforms.
    static func averageColor(of image: PlatformImage) -> Color? {
        guard let cgImage = image.tintSourceCGImage else { return nil }
        let fullHeight = CGFloat(cgImage.height)
        let sliceHeight = max(1, (fullHeight * sampledHeightFraction).rounded())
        // CGImage coordinates put the origin top-left, so the bottom slice
        // starts where the image ends minus the slice.
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

        // A fully transparent sample carries no colour information — treat it
        // as "no tint" rather than returning black, which would read as a
        // deliberate dark wash.
        guard pixel[3] > 0 else { return nil }
        return Color(
            .sRGB,
            red: Double(pixel[0]) / 255,
            green: Double(pixel[1]) / 255,
            blue: Double(pixel[2]) / 255,
            opacity: 1
        )
    }

    /// Test seam — the deck holds these for the life of the process, so a
    /// test that populates it would otherwise leak into the next one.
    static func resetCache() { cache.removeAll() }
}

extension PlatformImage {
    /// `CGImage` for colour sampling. NSImage has no direct accessor (it's a
    /// container of representations at different scales), so ask it to
    /// resolve one for its own size.
    var tintSourceCGImage: CGImage? {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }
}
