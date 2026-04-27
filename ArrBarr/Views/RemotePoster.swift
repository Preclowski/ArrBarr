import SwiftUI

struct RemotePoster: View {
    let url: URL?
    let apiKey: String?
    var size: CGSize = CGSize(width: 40, height: 60)
    var cornerRadius: CGFloat = 4
    var fallbackSymbol: String = "photo"

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
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
