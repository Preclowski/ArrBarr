import SwiftUI

public struct DiscoverCardView: View {
    let item: DiscoverItem

    public init(item: DiscoverItem) {
        self.item = item
    }

    public var body: some View {
        // GeometryReader gives us BOUNDED dimensions from whatever parent
        // sized us. We pass those explicitly to RemotePoster's `size`
        // (not fill mode) so the image is hard-clamped to the card frame.
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .bottomLeading) {
                // Solid black behind the image — keeps the card opaque
                // before the poster loads and on the side bands if the
                // poster's aspect doesn't match the card's.
                Color.black

                RemotePoster(
                    url: item.result.posterURL,
                    apiKey: nil,
                    size: CGSize(width: w, height: h),
                    cornerRadius: 0
                )

                // Top-left origin chip.
                originChip
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)

                // Bottom-left year chip (no title — poster art carries the identity).
                if let y = item.result.year {
                    Text(verbatim: "\(y)")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomLeading)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.28), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
        }
    }

    private var originChip: some View {
        HStack(spacing: 4) {
            Image(systemName: originIcon)
                .scaledFont(size: 10, weight: .semibold)
            Text(originLabel, bundle: .module)
                .scaledFont(size: 10, weight: .semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
    }

    private var originIcon: String {
        switch item.originLabel {
        case .tmdb:    return "film"
        case .library: return "books.vertical"
        case .llm:     return "sparkles"
        }
    }
    private var originLabel: LocalizedStringKey {
        switch item.originLabel {
        case .tmdb:    return "From TMDB"
        case .library: return "From your library"
        case .llm:     return "From AI"
        }
    }
}
