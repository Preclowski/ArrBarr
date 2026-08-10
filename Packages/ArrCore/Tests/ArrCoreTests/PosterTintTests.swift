import Testing
import Foundation
import CoreGraphics
import SwiftUI
@testable import ArrCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Builds a two-band image: `top` fills the upper half, `bottom` the lower.
/// The tint sampler is supposed to read the bottom third only, so a picture
/// whose halves disagree is the whole test.
private func bandedImage(top: (UInt8, UInt8, UInt8),
                         bottom: (UInt8, UInt8, UInt8),
                         size: Int = 60) -> PlatformImage? {
    let bytesPerRow = size * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * size)
    for y in 0..<size {
        let c = y < size / 2 ? top : bottom
        for x in 0..<size {
            let i = y * bytesPerRow + x * 4
            pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2; pixels[i + 3] = 255
        }
    }
    guard let context = pixels.withUnsafeMutableBytes({ raw -> CGContext? in
        CGContext(data: raw.baseAddress,
                  width: size, height: size,
                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }), let cgImage = context.makeImage() else { return nil }
    #if os(macOS)
    return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    #else
    return UIImage(cgImage: cgImage)
    #endif
}

private func components(_ color: Color) -> (r: Double, g: Double, b: Double) {
    let resolved = color.resolve(in: EnvironmentValues())
    return (Double(resolved.red), Double(resolved.green), Double(resolved.blue))
}

@Suite("Poster tint sampling")
@MainActor
struct PosterTintTests {

    /// The panel covers the bottom of the poster, so that's what it has to be
    /// coloured by. Sampling the whole image would tint the metadata with a
    /// poster's sky or title treatment — frequently nothing like the artwork
    /// the text actually sits on.
    @Test("The tint comes from the bottom of the poster, not the whole image")
    func samplesTheBottom() throws {
        let image = try #require(bandedImage(top: (255, 0, 0), bottom: (0, 0, 255)))
        let tint = try #require(PosterTint.averageColor(of: image))
        let (r, g, b) = components(tint)

        #expect(b > 0.8, "bottom band is blue, so the tint should be too")
        #expect(r < 0.2, "the red top band must not bleed into the sample")
        #expect(g < 0.2)
    }

    /// Reversing the bands has to reverse the answer — otherwise the test
    /// above would pass just as well on a sampler that always returns blue.
    @Test("Reversing the bands reverses the tint")
    func reversedBands() throws {
        let image = try #require(bandedImage(top: (0, 0, 255), bottom: (255, 0, 0)))
        let tint = try #require(PosterTint.averageColor(of: image))
        let (r, _, b) = components(tint)

        #expect(r > 0.8)
        #expect(b < 0.2)
    }

    /// A flat image averages to itself — the sanity check that the 1×1
    /// downsample isn't picking up an edge pixel or a premultiplication bug.
    @Test("A uniform image averages to its own colour")
    func uniformImage() throws {
        let image = try #require(bandedImage(top: (128, 64, 32), bottom: (128, 64, 32)))
        let tint = try #require(PosterTint.averageColor(of: image))
        let (r, g, b) = components(tint)

        #expect(abs(r - 128.0 / 255) < 0.02)
        #expect(abs(g - 64.0 / 255) < 0.02)
        #expect(abs(b - 32.0 / 255) < 0.02)
    }

    /// A transparent sample carries no colour. Returning black there would
    /// paint a deliberate-looking dark wash under the metadata of any poster
    /// that failed to decode.
    @Test("A fully transparent image yields no tint at all")
    func transparentImageHasNoTint() throws {
        let size = 8
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size)
        let cgImage = try #require(pixels.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress,
                      width: size, height: size,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        #if os(macOS)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        #else
        let image = UIImage(cgImage: cgImage)
        #endif

        #expect(PosterTint.averageColor(of: image) == nil)
    }

    /// No artwork, no tint — and crucially no crash from force-unwrapping a
    /// nil URL on a card whose poster never arrived.
    @Test("A nil poster URL resolves to no tint")
    func nilURL() async {
        PosterTint.resetCache()
        #expect(await PosterTint.color(for: nil) == nil)
    }
}
