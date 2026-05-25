import SwiftUI

/// Build the colored rating chips for a SearchResult — same vocabulary
/// as queue/search rows (IMDb yellow, RT red, MC green, ★ TMDB fallback).
func discoverRatingChips(for result: SearchResult) -> [RatingChip] {
    var out: [RatingChip] = []
    if let imdb = result.imdb {
        out.append(RatingChip(label: "IMDb", value: String(format: "%.1f", imdb), color: .yellow))
    }
    if let rt = result.rottenTomatoes {
        out.append(RatingChip(label: "RT", value: "\(Int(rt))%", color: .red))
    }
    if let mc = result.metacritic {
        out.append(RatingChip(label: "MC", value: "\(Int(mc))", color: .green))
    }
    if result.imdb == nil, let r = result.rating {
        out.append(RatingChip(label: "★", value: String(format: "%.1f", r), color: .yellow))
    }
    return out
}

public struct DiscoverCardView: View {
    let item: DiscoverItem
    @Binding var isHovered: Bool
    var dragOffset: CGSize = .zero

    public init(item: DiscoverItem,
                isHovered: Binding<Bool>,
                dragOffset: CGSize = .zero) {
        self.item = item
        self._isHovered = isHovered
        self.dragOffset = dragOffset
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // FRONT — rotates 0 → -180° on flip
                frontFace(w: w, h: h)
                    .opacity(isHovered ? 0 : 1)
                    .rotation3DEffect(
                        .degrees(isHovered ? -180 : 0),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.5
                    )

                // BACK — rotates +180° → 0 on flip
                backFace(w: w, h: h)
                    .opacity(isHovered ? 1 : 0)
                    .rotation3DEffect(
                        .degrees(isHovered ? 0 : 180),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.5
                    )
            }
            .frame(width: w, height: h)
            .animation(.interactiveSpring(response: 0.4, dampingFraction: 0.78), value: isHovered)
            .overlay(swipeTint.allowsHitTesting(false))
            .overlay(alignment: dragOffset.width > 0 ? .topLeading : .topTrailing) {
                swipeStamp
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
            .onHover { hovering in
                isHovered = hovering && abs(dragOffset.width) < 10
            }
        }
    }

    // MARK: - Front face

    @ViewBuilder
    private func frontFace(w: CGFloat, h: CGFloat) -> some View {
        // Poster + footer plate, hard edge between them.
        let footerH: CGFloat = 110
        let posterH = h - footerH

        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                RemotePoster(
                    url: item.result.posterURL,
                    apiKey: nil,
                    size: CGSize(width: w, height: posterH),
                    cornerRadius: 0
                )
                .frame(width: w, height: posterH)
                .clipped()

                // Only chrome on the poster art: source badge top-right.
                originChip
                    .padding(10)
            }

            // FOOTER PLATE — solid color, no material, no gradient.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.result.title)
                        .scaledFont(size: 17, weight: .semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let y = item.result.year {
                        Text(verbatim: "\(y)")
                            .scaledFont(size: 13, weight: .medium, monospacedDigit: true)
                            .foregroundStyle(.tertiary)
                    }
                }
                if !runtimeCertSegments.isEmpty {
                    Text(runtimeCertSegments.joined(separator: " · "))
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                let chips = discoverRatingChips(for: item.result)
                if !chips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(chips, id: \.label) { RatingPill(chip: $0) }
                    }
                }
                if !item.result.genres.isEmpty {
                    Text(item.result.genres.prefix(4).joined(separator: " · "))
                        .scaledFont(size: 11)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(width: w, height: footerH, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: w, height: h)
    }

    // MARK: - Back face

    @ViewBuilder
    private func backFace(w: CGFloat, h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                RemotePoster(
                    url: item.result.posterURL,
                    apiKey: nil,
                    size: CGSize(width: 40, height: 60),
                    cornerRadius: 4
                )
                .frame(width: 40, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.result.title)
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if let y = item.result.year {
                            Text(verbatim: "\(y)")
                                .scaledFont(size: 12, weight: .medium, monospacedDigit: true)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !runtimeCertSegments.isEmpty {
                        Text(runtimeCertSegments.joined(separator: " · "))
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    let chips = discoverRatingChips(for: item.result)
                    if !chips.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(chips, id: \.label) { RatingPill(chip: $0) }
                        }
                    }
                }
            }

            Divider()

            if let overview = item.result.overview, !overview.isEmpty {
                ScrollView {
                    Text(overview)
                        .scaledFont(size: 13)
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No overview available", bundle: .module)
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
            }

            if !item.result.genres.isEmpty {
                Divider()
                Text(item.result.genres.joined(separator: ", "))
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: w, height: h, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Shared helpers

    private var runtimeCertSegments: [String] {
        [
            item.result.runtime.flatMap { $0 > 0 ? "\($0 / 60)h \($0 % 60)m" : nil },
            item.result.certification.flatMap { $0.isEmpty ? nil : $0 },
            item.result.network.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }

    @ViewBuilder
    private var originChip: some View {
        switch item.originLabel {
        case .library: InLibraryBadge()
        case .tmdb:    TagChip(text: "Discover", color: .blue)
        case .llm:     TagChip(text: "AI", color: .purple)
        }
    }

    // MARK: - Swipe tint / stamp (unchanged from previous task)

    @ViewBuilder
    private var swipeTint: some View {
        let progress = min(1.0, abs(dragOffset.width) / 180)
        if abs(dragOffset.width) > 4 {
            Rectangle()
                .fill(dragOffset.width > 0 ? Color.accentColor : Color.red)
                .opacity(progress * 0.40)
        }
    }

    @ViewBuilder
    private var swipeStamp: some View {
        let progress = min(1.0, abs(dragOffset.width) / 180)
        if abs(dragOffset.width) > 30 {
            let isPick = dragOffset.width > 0
            Text(LocalizedStringKey(isPick ? "Pick" : "Skip"), bundle: .module)
                .scaledFont(size: 28, weight: .heavy)
                .textCase(.uppercase)
                .foregroundStyle(isPick ? Color.accentColor : Color.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isPick ? Color.accentColor : Color.red, lineWidth: 3)
                )
                .rotationEffect(.degrees(isPick ? 15 : -15))
                .opacity(progress)
                .padding(24)
                .allowsHitTesting(false)
        }
    }
}
