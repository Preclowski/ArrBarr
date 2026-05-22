import SwiftUI

/// Wraps a poster (or any view) and blurs it until tapped, when `blurred` is true.
/// Used to hide NSFW Whisparr posters by default. Reveal is per-instance and
/// session-only — closing the view restores the blur.
public struct PosterBlurContainer<Content: View>: View {
    let blurred: Bool
    @ViewBuilder let content: () -> Content
    @State private var revealed = false

    public init(blurred: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.blurred = blurred
        self.content = content
    }

    public var body: some View {
        content()
            .blur(radius: (blurred && !revealed) ? 12 : 0)
            .contentShape(Rectangle())
            .onTapGesture {
                if blurred { revealed.toggle() }
            }
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
