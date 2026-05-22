import SwiftUI

/// Wraps a poster (or any view) and blurs it when `blurred` is true. Used to
/// hide NSFW Whisparr posters. There's no tap-to-reveal — toggle is a global
/// preference in Settings, not a per-poster trick.
///
/// SwiftUI's `.blur(radius:)` is a Gaussian convolution that bleeds past the
/// content's frame, producing fuzzy edges past the poster. We `.compositingGroup()`
/// to rasterize the blur, then `.clipShape(RoundedRectangle)` to confine it back
/// to the poster's shape so the bleed disappears.
public struct PosterBlurContainer<Content: View>: View {
    let blurred: Bool
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    public init(blurred: Bool, cornerRadius: CGFloat = 4, @ViewBuilder content: @escaping () -> Content) {
        self.blurred = blurred
        self.cornerRadius = cornerRadius
        self.content = content
    }

    public var body: some View {
        content()
            .blur(radius: blurred ? 12 : 0)
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

public struct RemotePoster: View {
    let url: URL?
    let apiKey: String?
    var size: CGSize = CGSize(width: 40, height: 60)
    var cornerRadius: CGFloat = 4
    var fallbackSymbol: String = "photo"

    @State private var image: PlatformImage?
    @State private var failed = false

    public var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: min(size.width, size.height) * 0.4, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            image = nil
            failed = false
            return
        }
        let key = apiKey
        let result = await ImageCache.shared.image(for: url, apiKey: key)
        await MainActor.run {
            image = result
            failed = (result == nil)
        }
    }
}
