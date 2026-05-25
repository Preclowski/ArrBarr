import SwiftUI

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

            // Bottom info block — title + year + metadata strip + genres.
            VStack(alignment: .leading, spacing: 4) {
                Text(item.result.title)
                    .scaledFont(size: 18, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)

                HStack(spacing: 6) {
                    if let y = item.result.year {
                        Text(verbatim: "\(y)")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    if let runtime = item.result.runtime, runtime > 0 {
                        Text("•").foregroundStyle(.white.opacity(0.5))
                        Text(verbatim: "\(runtime) min")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if let cert = item.result.certification, !cert.isEmpty {
                        Text("•").foregroundStyle(.white.opacity(0.5))
                        Text(cert)
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(.white.opacity(0.6), lineWidth: 0.5)
                            )
                    }
                }
                .scaledFont(size: 11)

                if !item.result.genres.isEmpty {
                    Text(item.result.genres.prefix(3).joined(separator: " · "))
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(14)
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
        VStack(alignment: .leading, spacing: 8) {
            // Header row: title + year + origin chip
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.result.title)
                        .scaledFont(size: 16, weight: .bold)
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

            // Metadata strip: runtime · cert · network
            if !metadataStripSegments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(metadataStripSegments.enumerated()), id: \.offset) { idx, seg in
                        if idx > 0 {
                            Text("•").scaledFont(size: 10).foregroundStyle(.white.opacity(0.4))
                        }
                        Text(seg)
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }

            // Genres row — small chips, max 4
            if !item.result.genres.isEmpty {
                HStack(spacing: 4) {
                    ForEach(item.result.genres.prefix(4), id: \.self) { g in
                        Text(g)
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                    Spacer(minLength: 0)
                }
            }

            // Ratings row — IMDb / RT / MC / TMDB ★
            if !ratingChips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(ratingChips, id: \.label) { chip in
                        HStack(spacing: 3) {
                            Text(chip.label)
                                .scaledFont(size: 9, weight: .bold)
                                .foregroundStyle(chip.color)
                            Text(chip.value)
                                .scaledFont(size: 10, weight: .semibold)
                                .foregroundStyle(.white.opacity(0.92))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.1)))
                    }
                    Spacer(minLength: 0)
                }
            }

            Divider().opacity(0.25)

            // Scrollable overview. allowsHitTesting(true) by default so
            // the user can actually scroll. The card-swipe drag gesture
            // lives on the parent and is disabled while the card is flipped.
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

    /// Metadata segments shown as " · "-joined strip below the title.
    private var metadataStripSegments: [String] {
        [
            item.result.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
            item.result.certification.flatMap { $0.isEmpty ? nil : $0 },
            item.result.network.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }

    /// Rating chips — each with a label, value, and color.
    private struct CardRatingChip { let label: String; let value: String; let color: Color }

    private var ratingChips: [CardRatingChip] {
        var out: [CardRatingChip] = []
        if let imdb = item.result.imdb {
            out.append(.init(label: "IMDb", value: String(format: "%.1f", imdb), color: .yellow))
        }
        if let rt = item.result.rottenTomatoes {
            out.append(.init(label: "RT", value: "\(Int(rt))%", color: .red))
        }
        if let mc = item.result.metacritic {
            out.append(.init(label: "MC", value: "\(Int(mc))", color: .green))
        }
        if item.result.imdb == nil, let rating = item.result.rating {
            out.append(.init(label: "★", value: String(format: "%.1f", rating), color: .yellow))
        }
        return out
    }
}
