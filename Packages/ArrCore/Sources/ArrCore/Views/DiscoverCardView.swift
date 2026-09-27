import SwiftUI

func discoverRatingChips(for result: SearchResult, imdbId: String? = nil) -> [RatingChip] {
    // Without `linkTitle` the factories build an inert, unclickable chip.
    let title = result.title
    var out: [RatingChip] = [
        result.imdb.flatMap { RatingChip.imdb($0, linkTitle: title, imdbId: result.imdbId ?? imdbId) },
        result.rottenTomatoes.flatMap { RatingChip.rottenTomatoes($0, linkTitle: title) },
        result.metacritic.flatMap { RatingChip.metacritic($0, linkTitle: title) },
    ].compactMap { $0 }
    if result.imdb == nil, let r = result.rating {
        let id = result.externalId > 0 ? result.externalId : nil
        let chip = result.source == .sonarr
            ? RatingChip.tvdb(r, linkTitle: title, tvdbId: id)
            : RatingChip.tmdb(r, linkTitle: title, tmdbId: id)
        if let chip { out.append(chip) }
    }
    return out
}

/// The immersive Quiz card: full-bleed poster, bottom scrim with the metadata,
/// and a "More" link to the full detail card.
struct DiscoverCardView: View {
    let item: DiscoverItem
    var dragOffset: CGSize = .zero
    var bottomInset: CGFloat = 0
    var onMore: () -> Void

    /// Resolved per poster URL, so the peek card has it before reaching the top.
    @State private var posterTint: Color?
    @State private var directors: [CastMember] = []
    /// TMDB-sourced cards carry no IMDb id; until it lands the IMDb pill opens a title search.
    @State private var resolvedIMDbId: String?
    @EnvironmentObject private var configStore: ConfigStore

    init(item: DiscoverItem,
                dragOffset: CGSize = .zero,
                bottomInset: CGFloat = 0,
                onMore: @escaping () -> Void = {}) {
        self.item = item
        self.dragOffset = dragOffset
        self.bottomInset = bottomInset
        self.onMore = onMore
    }

    private func loadCredits() async {
        let result = item.result
        switch item.kind {
        case .movie:
            let tmdbId = result.externalId > 0 ? result.externalId : Int(result.foreignId)
            directors = await CastProvider.movieCredits(
                radarrMovieId: result.inLibraryArrId,
                tmdbId: tmdbId,
                configStore: configStore).directors
            if result.imdbId == nil, let tmdbId, tmdbId > 0, !configStore.tmdbApiKey.isEmpty {
                resolvedIMDbId = try? await configStore.tmdbClient.movieIMDbId(movieId: tmdbId)
            }
        case .show:
            directors = await CastProvider.seriesCredits(
                tmdbId: result.tmdbTVId,
                tvdbId: result.externalId > 0 ? result.externalId : nil,
                configStore: configStore).directors
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottomLeading) {
                RemotePoster(
                    url: item.result.posterURL,
                    apiKey: nil,
                    size: CGSize(width: w, height: h),
                    cornerRadius: 0,
                    fallbackSymbol: "film",
                    fill: true,
                    showsLoadingIndicator: true
                )
                .frame(width: w, height: h)
                .clipped()
                // Watched wedge only: a deck card has no arr record, so no monitored flag.
                .posterMarks(watched: MediaServerIndex.shared.isWatched(item.result.mediaServerKeys),
                             monitored: nil, cornerRadius: 0, ribbonWidth: 14)

                bottomGlassPanel(h: h * 0.55)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)

                metadata
                    .padding(16)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(width: w, height: h)
            // No rounded corners: NSPopover masks the card to the window's own corners.
            .overlay(swipeTint.allowsHitTesting(false))
            .overlay(alignment: dragOffset.width > 0 ? .topLeading : .topTrailing) {
                swipeStamp
            }
            .task(id: item.result.posterURL) {
                posterTint = await PosterTint.color(for: item.result.posterURL)
            }
            .task(id: item.id) { await loadCredits() }
        }
    }

    // MARK: - Metadata block

    @ViewBuilder
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleAndYear)
                .scaledFont(size: 19, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(2)
            // Without the badge a library pick reads as the quiz suggesting things you already have.
            if item.result.inLibraryArrId != nil {
                LibraryStateBadge(isDownloaded: item.result.libraryDownloaded)
            }
            if !runtimeCertSegments.isEmpty {
                Text(runtimeCertSegments.joined(separator: " · "))
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            let chips = discoverRatingChips(for: item.result, imdbId: resolvedIMDbId)
            if !chips.isEmpty {
                HStack(spacing: 5) {
                    ForEach(chips, id: \.label) { RatingPill(chip: $0) }
                }
            }
            DirectedByLine(people: directors,
                           labelKey: item.kind == .show ? "detail.createdBy.label" : "detail.directedBy.label")
            if let overview = item.result.overview, !overview.isEmpty {
                Text(overview)
                    .scaledFont(size: 12)
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
            if let reason = item.reason, !reason.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .scaledFont(size: 9, weight: .semibold)
                    Text(reason)
                        .scaledFont(size: 11, weight: .medium)
                        .lineLimit(1)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
            }
            moreButton
        }
    }

    private var moreButton: some View {
        Button(action: onMore) {
            HStack(spacing: 3) {
                Text("discover.moreDetails.button", bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 9, weight: .bold)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("discover.moreDetails.button", bundle: .module))
        #if os(macOS)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }

    // MARK: - Helpers

    private var titleAndYear: String {
        if let y = item.result.year {
            return "\(item.result.title) (\(y))"
        }
        return item.result.title
    }

    private var runtimeCertSegments: [String] {
        [
            item.result.runtime.flatMap { $0 > 0 ? "\($0 / 60)h \($0 % 60)m" : nil },
            item.result.certification.flatMap { $0.isEmpty ? nil : $0 },
            item.result.network.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }

    /// No `.regularMaterial`: in the deck's ZStack it samples the sibling card and
    /// settles a beat late. Both layers here are values this card owns.
    @ViewBuilder
    private func bottomGlassPanel(h: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [.clear, .black.opacity(0.55), .black.opacity(0.88)],
                startPoint: .top, endPoint: .bottom
            )
            LinearGradient(
                colors: [.clear, (posterTint ?? .clear).opacity(0.4), (posterTint ?? .clear).opacity(0.62)],
                startPoint: .top, endPoint: .bottom
            )
            .animation(.easeInOut(duration: 0.3), value: posterTint)
        }
        .frame(height: h)
    }


    // MARK: - Swipe tint / stamp

    @ViewBuilder
    private var swipeTint: some View {
        let progress = min(1.0, abs(dragOffset.width) / 180)
        if abs(dragOffset.width) > 4 {
            Rectangle()
                .fill(dragOffset.width > 0 ? Color.accentColor : Color.secondary)
                .opacity(progress * 0.40)
        }
    }

    @ViewBuilder
    private var swipeStamp: some View {
        let progress = min(1.0, abs(dragOffset.width) / 180)
        if abs(dragOffset.width) > 30 {
            let isAdd = dragOffset.width > 0
            Text(LocalizedStringKey(isAdd ? "Add" : "Skip"), bundle: .module)
                .scaledFont(size: 28, weight: .heavy)
                .textCase(.uppercase)
                .foregroundStyle(isAdd ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isAdd ? Color.accentColor : Color.secondary, lineWidth: 3)
                )
                .rotationEffect(.degrees(isAdd ? 15 : -15))
                .opacity(progress)
                .padding(24)
                .allowsHitTesting(false)
        }
    }
}
