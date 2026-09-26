import SwiftUI

/// Build the colored rating chips for a SearchResult — same vocabulary
/// as queue/search rows (IMDb yellow, RT red, MC green, ★ TMDB fallback).
func discoverRatingChips(for result: SearchResult, imdbId: String? = nil) -> [RatingChip] {
    // `linkTitle` is what makes a pill clickable (see `RatingChip`): without it
    // the factories build an inert chip, which is why the Quiz's scores opened
    // nothing while the detail card's did.
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

/// The immersive Quiz card: a single full-bleed poster with a bottom glass
/// scrim carrying the title / meta / a short overview and a "Więcej" link
/// that opens the full detail card. Swipe tint + stamp overlays give the
/// drag its like/skip feedback. No hover-flip back face — details live on
/// the detail card the "Więcej" link opens.
public struct DiscoverCardView: View {
    let item: DiscoverItem
    var dragOffset: CGSize = .zero
    /// Vertical space reserved at the bottom for the floating action
    /// buttons so the metadata never slides under them.
    var bottomInset: CGFloat = 0
    /// Opens the full movie/series detail card.
    var onMore: () -> Void

    /// Dominant colour of the poster's lower edge — see `bottomGlassPanel`.
    /// Resolved per poster URL, so the peek card has it in hand well before
    /// it reaches the top of the deck.
    @State private var posterTint: Color?
    /// Director (movie) or creators (series) — the same byline the detail
    /// card carries, in the same slot: under the ratings, above the synopsis.
    @State private var directors: [CastMember] = []
    /// Resolved for TMDB-sourced cards, which carry no IMDb id — see
    /// `TMDBClient.movieIMDbId`. Until it lands the IMDb pill opens a title
    /// search, which is what it did before.
    @State private var resolvedIMDbId: String?
    @EnvironmentObject private var configStore: ConfigStore

    public init(item: DiscoverItem,
                dragOffset: CGSize = .zero,
                bottomInset: CGFloat = 0,
                onMore: @escaping () -> Void = {}) {
        self.item = item
        self.dragOffset = dragOffset
        self.bottomInset = bottomInset
        self.onMore = onMore
    }

    /// Credits for the card on screen. `CastProvider` caches and coalesces per
    /// title, so a card the user swipes back to costs nothing, and a title they
    /// open in detail afterwards is already resolved.
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
                resolvedIMDbId = try? await TMDBClient(apiKey: configStore.tmdbApiKey).movieIMDbId(movieId: tmdbId)
            }
        case .show:
            directors = await CastProvider.seriesCredits(
                tmdbId: result.tmdbTVId,
                tvdbId: result.externalId > 0 ? result.externalId : nil,
                configStore: configStore).directors
        }
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottomLeading) {
                // Full-bleed poster — fills the whole popover (2:3, no crop).
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
                // Watched wedge only: a deck card carries no arr record, so
                // there is no monitored flag to draw.
                .posterMarks(watched: MediaServerIndex.shared.isWatched(item.result.mediaServerKeys),
                             monitored: nil, cornerRadius: 0, ribbonWidth: 14)

                // Bottom scrim — transparent at the top, opaque glass at the
                // bottom — so text + buttons read over any artwork.
                bottomGlassPanel(h: h * 0.55)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)

                // Title / meta / overview / "Więcej", lifted above the
                // floating action buttons by `bottomInset`.
                metadata
                    .padding(16)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(width: w, height: h)
            // Rounded corners / rim / shadow are intentionally absent: the
            // card fills the popover and NSPopover masks it to the window's
            // own rounded corners.
            .overlay(swipeTint.allowsHitTesting(false))
            .overlay(alignment: dragOffset.width > 0 ? .topLeading : .topTrailing) {
                swipeStamp
            }
            // Runs for the peek card too — it's rendered (behind the top card),
            // so its tint is resolved before the user ever sees it.
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
            // Owned titles say so up front — without the badge a deliberate
            // library pick reads as the quiz suggesting things you already
            // have. Same chip the search results / detail views use.
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
            // Byline between the ratings and the synopsis, exactly where the
            // detail card puts it (see `MediaHeaderCard`).
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
            // Why-this-card line: makes the pick legible ("Because you kept
            // Sicario") and turns a miss from "the app is dumb" into "ah,
            // that's why — no thanks". Absent when no source gave a reason.
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

    /// The "Więcej" affordance — opens the full detail / add card.
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

    /// The scrim under the metadata: a dark base for legibility, washed with
    /// this card's OWN poster colour.
    ///
    /// There is deliberately no `.regularMaterial` here any more. A material
    /// takes its colour from whatever it samples behind itself — which, in the
    /// deck's ZStack, is the *sibling card*, not this one. So every card's
    /// panel was partly painted by its neighbour, and the sample settled a
    /// beat after the swap: the card changed, then its colour caught up. No
    /// amount of tint layered on top fixes that, because the lagging colour is
    /// still underneath.
    ///
    /// Now both layers are values this card owns. `posterTint` is resolved
    /// from its own pixels while it is still the hidden peek card, so it is
    /// already correct the moment it reaches the top of the deck, and it
    /// cross-fades rather than snapping when it does arrive.
    @ViewBuilder
    private func bottomGlassPanel(h: CGFloat) -> some View {
        ZStack {
            // Legibility floor — independent of the artwork, so text contrast
            // never depends on how bright a given poster happens to be.
            LinearGradient(
                colors: [.clear, .black.opacity(0.55), .black.opacity(0.88)],
                startPoint: .top, endPoint: .bottom
            )
            // The card's own colour, over the top of that floor.
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
