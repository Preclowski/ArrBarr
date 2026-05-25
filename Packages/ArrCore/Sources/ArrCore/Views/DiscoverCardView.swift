import SwiftUI

public struct DiscoverCardView: View {
    let item: DiscoverItem

    @State private var isFlipped: Bool = false

    public init(item: DiscoverItem) {
        self.item = item
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Front face — poster + overlays.
                frontFace(w: w, h: h)
                    .opacity(isFlipped ? 0 : 1)
                    .rotation3DEffect(.degrees(isFlipped ? 180 : 0),
                                      axis: (x: 0, y: 1, z: 0),
                                      perspective: 0.6)

                // Back face — overview + ratings.
                // Mirrored so it reads correctly after the flip.
                backFace(w: w, h: h)
                    .opacity(isFlipped ? 1 : 0)
                    .rotation3DEffect(.degrees(isFlipped ? 0 : -180),
                                      axis: (x: 0, y: 1, z: 0),
                                      perspective: 0.6)
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: isFlipped)
            .onHover { hovering in
                isFlipped = hovering
            }
        }
    }

    // MARK: - Front face

    @ViewBuilder
    private func frontFace(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.black

            RemotePoster(
                url: item.result.posterURL,
                apiKey: nil,
                size: CGSize(width: w, height: h),
                cornerRadius: 0
            )

            // Origin chip top-left
            originChip
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)

            // Title + year stacked bottom-left
            VStack(alignment: .leading, spacing: 4) {
                Text(item.result.title)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))

                if let y = item.result.year {
                    Text(verbatim: "\(y)")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .bottomLeading)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
    }

    // MARK: - Back face

    @ViewBuilder
    private func backFace(w: CGFloat, h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title + year header, origin badge on the right
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.result.title)
                        .scaledFont(size: 15, weight: .bold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let y = item.result.year {
                        Text(verbatim: "\(y)")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()
                originChip
            }

            // Ratings row — only show segments that exist
            if !ratingsSegments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(ratingsSegments, id: \.self) { seg in
                        Text(seg)
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }

            // Overview text
            if let overview = item.result.overview, !overview.isEmpty {
                ScrollView {
                    Text(overview)
                        .scaledFont(size: 12)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .allowsHitTesting(false)
            } else {
                Text("No overview available", bundle: .module)
                    .scaledFont(size: 12)
                    .foregroundStyle(.white.opacity(0.6))
            }

            // Genre chips
            if !item.result.genres.isEmpty {
                HStack(spacing: 4) {
                    ForEach(item.result.genres.prefix(4), id: \.self) { g in
                        TagChip(text: g, color: .gray)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(width: w, height: h, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
    }

    // MARK: - Shared helpers

    @ViewBuilder
    private var originChip: some View {
        switch item.originLabel {
        case .library:
            InLibraryBadge()
        case .tmdb:
            TagChip(text: "Discover", color: .blue)
        case .llm:
            TagChip(text: "AI", color: .purple)
        }
    }

    private var ratingsSegments: [String] {
        [
            item.result.imdb.map { String(format: "IMDb %.1f", $0) },
            item.result.rottenTomatoes.map { "RT \(Int($0))%" },
            item.result.metacritic.map { "MC \(Int($0))" },
            item.result.imdb == nil
                ? item.result.rating.map { String(format: "★ %.1f", $0) }
                : nil,
            item.result.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
        ].compactMap { $0 }
    }
}
