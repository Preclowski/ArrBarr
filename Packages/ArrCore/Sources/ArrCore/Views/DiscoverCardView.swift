import SwiftUI

/// Build the colored rating chips for a SearchResult — same vocabulary
/// as queue/search rows (IMDb yellow, RT red, MC green, ★ TMDB fallback).
func discoverRatingChips(for result: SearchResult) -> [RatingChip] {
    var out: [RatingChip] = []
    if let imdb = result.imdb {
        out.append(RatingChip(label: "IMDb",
                              value: String(format: "%.1f", imdb),
                              color: .yellow))
    }
    if let rt = result.rottenTomatoes {
        out.append(RatingChip(label: "RT", value: "\(Int(rt))%", color: .red))
    }
    if let mc = result.metacritic {
        out.append(RatingChip(label: "MC", value: "\(Int(mc))", color: .green))
    }
    if result.imdb == nil, let r = result.rating {
        out.append(RatingChip(label: "★",
                              value: String(format: "%.1f", r),
                              color: .yellow))
    }
    return out
}

public struct DiscoverCardView: View {
    let item: DiscoverItem
    @Binding var isFlipped: Bool

    public init(item: DiscoverItem, isFlipped: Binding<Bool>) {
        self.item = item
        self._isFlipped = isFlipped
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

    // MARK: - Shared helpers

    private var titleWithYear: String {
        if let y = item.result.year { return "\(item.result.title) (\(y))" }
        return item.result.title
    }

    private var runtimeCertSegments: [String] {
        [
            item.result.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
            item.result.certification.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }

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

            // Bottom dark gradient — covers ~38% of card height for
            // the info block below to read clearly.
            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.0)],
                startPoint: .bottom, endPoint: .top
            )
            .frame(height: h * 0.38)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            // Bottom info block — title(year) / runtime·cert / ratings / genres
            VStack(alignment: .leading, spacing: 4) {
                Text(titleWithYear)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !runtimeCertSegments.isEmpty {
                    Text(runtimeCertSegments.joined(separator: " · "))
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(.white.opacity(0.85))
                }

                let chips = discoverRatingChips(for: item.result)
                if !chips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(chips, id: \.label) { RatingPill(chip: $0) }
                    }
                    .padding(.top, 1)
                }

                if !item.result.genres.isEmpty {
                    Text(item.result.genres.prefix(3).joined(separator: " · "))
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(titleWithYear)
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !runtimeCertSegments.isEmpty {
                        Text(runtimeCertSegments.joined(separator: " · "))
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer()
                originChip
            }

            let chips = discoverRatingChips(for: item.result)
            if !chips.isEmpty {
                HStack(spacing: 5) {
                    ForEach(chips, id: \.label) { RatingPill(chip: $0) }
                }
            }

            if !item.result.genres.isEmpty {
                Text(item.result.genres.prefix(4).joined(separator: " · "))
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }

            Divider().opacity(0.25)

            if let overview = item.result.overview, !overview.isEmpty {
                ScrollView {
                    Text(overview)
                        .scaledFont(size: 12)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No overview available", bundle: .module)
                    .scaledFont(size: 12)
                    .foregroundStyle(.white.opacity(0.55))
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
}
