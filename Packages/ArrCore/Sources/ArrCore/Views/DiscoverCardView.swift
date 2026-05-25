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
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 6)
            .onHover { hovering in
                isHovered = hovering && abs(dragOffset.width) < 10
            }
        }
    }

    // MARK: - Front face

    @ViewBuilder
    private func frontFace(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Full-card raw poster.
            RemotePoster(
                url: item.result.posterURL,
                apiKey: nil,
                size: CGSize(width: w, height: h),
                cornerRadius: 0
            )
            .frame(width: w, height: h)
            .clipped()

            // Origin chip top-right on the poster.
            originChip
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Glass panel at the bottom — fades from transparent at top
            // to opaque glass at the bottom. Covers ~55% of card height
            // so the metadata sits on the dense glass region.
            bottomGlassPanel(h: h * 0.55)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            // Metadata sits on the dense (bottom) part of the glass panel.
            VStack(alignment: .leading, spacing: 5) {
                Text(titleAndYear)
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(.primary)
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
                genreLabels(limit: 6)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: w, height: h)
    }

    /// Glass material masked by a vertical gradient — transparent at top,
    /// fully opaque (= visible glass blur) at bottom.
    @ViewBuilder
    private func bottomGlassPanel(h: CGFloat) -> some View {
        Rectangle()
            .fill(.regularMaterial)
            .mask(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.8), .black],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(height: h)
    }

    // MARK: - Back face

    @ViewBuilder
    private func backFace(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .top) {
            // Full-card poster underneath — barely peeks through at the
            // very top where the glass panel fades.
            RemotePoster(
                url: item.result.posterURL,
                apiKey: nil,
                size: CGSize(width: w, height: h),
                cornerRadius: 0
            )
            .frame(width: w, height: h)
            .clipped()

            // Glass panel covers ~92% of card from top down, fading the
            // first ~8% from transparent to opaque so a sliver of poster
            // peeks through.
            topGlassPanel(h: h)
                .frame(height: h)
                .allowsHitTesting(false)

            // Reading content sits on the dense glass region.
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleAndYear)
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(.primary)
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
                }

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

                genreLabels(limit: 12)
            }
            .padding(.top, 28)   // skip the transparent fade region
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(width: w, height: h, alignment: .topLeading)
        }
        .frame(width: w, height: h)
    }

    /// Glass material covering most of the card. Fades from transparent
    /// at the very top edge (showing the poster underneath) to fully
    /// opaque glass below. The user sees the panel as a single sheet of
    /// frosted glass laid over the poster.
    @ViewBuilder
    private func topGlassPanel(h: CGFloat) -> some View {
        Rectangle()
            .fill(.regularMaterial)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.7), location: 0.08),
                        .init(color: .black, location: 0.18),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
    }

    // MARK: - Shared helpers

    private var titleAndYear: String {
        if let y = item.result.year {
            return "\(item.result.title) (\(y))"
        }
        return item.result.title
    }

    @ViewBuilder
    private func genreLabels(limit: Int) -> some View {
        let visible = Array(item.result.genres.prefix(limit))
        if !visible.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(visible, id: \.self) { g in
                    Text(g)
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.5), lineWidth: 0.75)
                        )
                }
            }
        }
    }

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
