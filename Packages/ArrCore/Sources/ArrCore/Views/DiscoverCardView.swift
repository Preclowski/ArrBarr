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
    var credits: TMDBCredits?

    public init(item: DiscoverItem,
                isHovered: Binding<Bool>,
                dragOffset: CGSize = .zero,
                credits: TMDBCredits? = nil) {
        self.item = item
        self._isHovered = isHovered
        self.dragOffset = dragOffset
        self.credits = credits
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                frontFace(w: w, h: h)
                    .opacity(isHovered ? 0 : 1)
                    .blur(radius: isHovered ? 8 : 0)
                backFace(w: w, h: h)
                    .opacity(isHovered ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.28), value: isHovered)
            .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 6)
            .overlay(swipeTint.allowsHitTesting(false))
            .overlay(alignment: dragOffset.width > 0 ? .topLeading : .topTrailing) {
                swipeStamp
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
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
        let headerH: CGFloat = h * 0.38

        ZStack(alignment: .top) {
            // Raw poster underneath the entire card.
            RemotePoster(
                url: item.result.posterURL,
                apiKey: nil,
                size: CGSize(width: w, height: h),
                cornerRadius: 0
            )
            .frame(width: w, height: h)
            .clipped()

            // Glass panel covers the bottom ~62% only — fades in at top.
            VStack(spacing: 0) {
                Spacer().frame(height: headerH * 0.7) // glass fade starts inside header
                Rectangle()
                    .fill(.regularMaterial)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black.opacity(0.85), location: 0.18),
                                .init(color: .black, location: 0.35),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
            .frame(width: w, height: h)
            .allowsHitTesting(false)

            // Content: header on poster (top), overview + genres on glass (bottom).
            VStack(alignment: .leading, spacing: 0) {
                // HEADER on poster, white text + shadows.
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleAndYear)
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                    if !runtimeCertSegments.isEmpty {
                        Text(runtimeCertSegments.joined(separator: " · "))
                            .scaledFont(size: 11)
                            .foregroundStyle(.white.opacity(0.95))
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                            .lineLimit(1)
                    }
                    let chips = discoverRatingChips(for: item.result)
                    if !chips.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(chips, id: \.label) { RatingPill(chip: $0) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: headerH, alignment: .topLeading)

                // EVERYTHING ELSE inside ScrollView — overview, genres,
                // director, cast all scroll together.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let overview = item.result.overview, !overview.isEmpty {
                            Text(overview)
                                .scaledFont(size: 13)
                                .foregroundStyle(.primary)
                                .lineSpacing(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("No overview available", bundle: .module)
                                .scaledFont(size: 12)
                                .foregroundStyle(.secondary)
                        }

                        genreLabels(limit: 12)

                        if let credits {
                            if let dirName = directorName(from: credits) {
                                HStack(spacing: 4) {
                                    Text("Directed by", bundle: .module)
                                        .scaledFont(size: 10, weight: .medium)
                                        .foregroundStyle(.secondary)
                                    Text(dirName)
                                        .scaledFont(size: 11, weight: .semibold)
                                        .foregroundStyle(.primary)
                                }
                                .padding(.top, 4)
                            }
                            if !credits.cast.isEmpty {
                                HStack(spacing: 8) {
                                    ForEach(credits.cast.prefix(4)) { person in
                                        VStack(spacing: 4) {
                                            personAvatar(person)
                                            Text(person.name)
                                                .scaledFont(size: 9, weight: .medium)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .frame(width: 50)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: w, height: h)
        }
        .frame(width: w, height: h)
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

    private func directorName(from credits: TMDBCredits) -> String? {
        credits.crew.first(where: { $0.job == "Director" })?.name
    }

    @ViewBuilder
    private func personAvatar(_ person: TMDBCreditPerson) -> some View {
        if let url = person.posterURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Image(systemName: "person.fill")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: "person.fill").foregroundStyle(.tertiary))
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
