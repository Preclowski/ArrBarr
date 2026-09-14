import SwiftUI
import AppKit

/// A brand's own mark as TMDB ships it — the streaming service that carries
/// the title, or the studio that made it. A logo is the fact where a name in
/// plain type would be a label ("Netflix" reads best in Netflix's letters);
/// a brand with no logo falls back to its name, which is still the answer.
struct BrandLogo: View {
    enum Style {
        /// A square, fully coloured tile: streaming services.
        case tile
        /// Transparent artwork of its own proportions: studio marks. TMDB is
        /// not consistent about how they are drawn — one company's is black
        /// on transparency, the next one's white — so rather than guess, the
        /// mark is measured and a dark one gets the light plate it needs.
        case mark
    }

    let name: String
    let url: URL?
    var height: CGFloat = 22
    var style: Style = .tile

    @State private var image: NSImage?

    var body: some View {
        content
            .help(Text(verbatim: name))
            .task(id: url) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            switch style {
            case .tile:
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: height, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: height * 0.24, style: .continuous))
            case .mark:
                let dark = LogoLuminance.isDark(image)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: dark ? height * 0.82 : height)
                    .padding(.horizontal, dark ? 5 : 0)
                    .padding(.vertical, dark ? 3 : 0)
                    .background {
                        if dark {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.white.opacity(0.85))
                        }
                    }
            }
        } else {
            Text(verbatim: name)
                .font(.caption.weight(.semibold))
                .opacity(0.85)
        }
    }

    private func load() async {
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        image = nil
        guard let downloaded = await ImageCache.download(url), !Task.isCancelled else { return }
        ImageCache.shared.store(downloaded, for: url)
        withAnimation(.easeOut(duration: 0.18)) { image = downloaded }
    }
}

/// "Is this mark drawn in dark ink?" — averaged over the pixels that are
/// actually there, so transparency never counts as white. Memoised: the same
/// studio comes back on every other title.
enum LogoLuminance {
    private static let cache = NSCache<NSString, NSNumber>()

    static func isDark(_ image: NSImage) -> Bool {
        let key = NSString(string: "\(ObjectIdentifier(image))")
        if let known = cache.object(forKey: key) { return known.boolValue }
        let dark = measure(image)
        cache.setObject(NSNumber(value: dark), forKey: key)
        return dark
    }

    private static func measure(_ image: NSImage) -> Bool {
        var rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return true }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var luminance = 0.0
        var coverage = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.05 else { continue }
            // Premultiplied: undo the alpha, or a faint edge reads as black.
            let r = Double(pixels[index]) / 255 / alpha
            let g = Double(pixels[index + 1]) / 255 / alpha
            let b = Double(pixels[index + 2]) / 255 / alpha
            luminance += (0.2126 * r + 0.7152 * g + 0.0722 * b) * alpha
            coverage += alpha
        }
        guard coverage > 0 else { return false }
        return luminance / coverage < 0.5
    }
}
