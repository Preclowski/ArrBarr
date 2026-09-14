import SwiftUI
import MediaKit
import SwiftData
import ArrCore

/// The Quiz: a full-bleed swipe deck. Random titles for now — the feed is a
/// plug-in point (`QuizFeed`) so smarter sources can slot in later without
/// touching the view. Right/♥ saves to the "Quiz Picks" list, left/✕ skips,
/// arrows work from the keyboard, the blurred backdrop tracks the drag.
struct QuizView: View {
    @EnvironmentObject private var config: TonightConfig
    @Environment(\.modelContext) private var context
    @Environment(\.openTitle) private var openTitle

    /// Deck, undo history and feed live outside the view so that leaving the
    /// tab and coming back resumes the same run instead of dealing afresh.
    @ObservedObject var session: QuizSession
    /// How to leave a deck that was dealt from a library page — handed down
    /// by `RootView`, which is the only thing that knows where the user was.
    /// `nil` for the endless feed: the Quiz tab is a destination of its own
    /// there, and a close button on it would have nowhere to go.
    var onClose: (() -> Void)?

    @State private var drag: CGSize = .zero
    @State private var flyOff: CGFloat = 0   // -1 left … 1 right while departing
    /// 0…1 while the top card leaves: how far the deck has already moved up
    /// one place. The card underneath grows into the top card's size along
    /// with the departure instead of snapping when it finally lands.
    @State private var promote: CGFloat = 0
    @State private var trailerKey: String?
    @State private var showTrailer = false
    @State private var ratings: MediaKit.Ratings?
    /// The card's full payload — the same one a title page draws its hero
    /// from, so the copy beside the deck is written in the hero's words
    /// (logo, claim, facts) rather than in the card's raw fields.
    @State private var details: TitleDetails?
    /// -1 (skip) … 1 (like) while a card is on its way out under the action
    /// buttons rather than under the hand. The drag speaks for itself; this
    /// is what makes the ✕ / ♥ answer a keyboard or a click too.
    @State private var kick: CGFloat = 0

    private var deck: [MediaItem] { session.deck }
    private var loading: Bool { session.loading }
    private var card: MediaItem? { session.deck.first }

    var body: some View {
        GeometryReader { proxy in
            // The deck-source line stands below the buttons, so the deck
            // gets that much less height when a collection is being swiped.
            let layout = QuizLayout(proxy.size,
                                    extraChrome: session.source.name == nil ? 0 : 34)
            VStack(spacing: layout.gap) {
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 44) {
                    deckStack(layout: layout, size: proxy.size)
                    if let card, layout.showsDescription {
                        description(of: card)
                            .frame(maxWidth: 400, alignment: .leading)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                            .id(card.id)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: card?.id)
                actionBar
                deckSourceLine
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.vertical, layout.gap)
        }
        .background { backdrop }
        .colorScheme(.dark)
        .overlay(alignment: .topTrailing) { closeDeckButton }
        .overlay {
            if deck.isEmpty {
                if loading {
                    ProgressView().controlSize(.large)
                } else if let name = session.source.name {
                    // A collection is finite: there is nothing left to deal,
                    // only the endless feed to go back to.
                    QuietMessage(systemImage: "sparkles",
                                 title: String(localized: "That's the whole collection", bundle: .module),
                                 subtitle: name,
                                 action: (String(localized: "Back to Random", bundle: .module),
                                          { Task { await session.resumeFeed(config: config) } }))
                } else {
                    QuietMessage(systemImage: "sparkles",
                                 title: String(localized: "Out of cards", bundle: .module),
                                 subtitle: nil,
                                 action: (String(localized: "Deal again", bundle: .module),
                                          { Task { await session.refill(config: config) } }))
                }
            }
        }
        .task { await session.refillIfNeeded(config: config) }
        // Decode the cards below the top one before they are needed: dealt
        // cold, the next card flashed a grey plate as the top one left.
        .task(id: deck.prefix(4).map(\.id)) {
            for item in deck.prefix(4) {
                ImageCache.shared.prefetch(item.displayLargePosterURL)
                ImageCache.shared.prefetch(item.backdropURL)
            }
        }
        .task(id: card?.id) { await enrich() }
        .sheet(isPresented: $showTrailer) {
            if let card, let trailerKey {
                TrailerSheet(youTubeKey: trailerKey, title: card.title)
            }
        }
    }

    /// The hero payload + multi-service ratings for the current card.
    private func enrich() async {
        guard let card else {
            trailerKey = nil; ratings = nil; details = nil
            return
        }
        // A title the session has already described (Home's marquee, a detail
        // page) is written straight away; only a cold card empties the column.
        let cached = DetailsCache.shared[card.id]
        details = cached
        trailerKey = cached?.trailerYouTubeKey
        ratings = nil
        // The field, not the service: whoever can answer `.ratings` does.
        async let external = MediaStack.shared.snapshot(for: card, fields: .ratings).ratings
        if cached == nil {
            let service = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
            if let loaded = try? await service.details(for: card),
               !Task.isCancelled, deck.first?.id == card.id {
                DetailsCache.shared.store(loaded, for: card.id)
                withAnimation(.easeOut(duration: 0.2)) {
                    details = loaded
                    trailerKey = loaded.trailerYouTubeKey
                }
            }
        }
        let foundRatings = await external
        guard !Task.isCancelled, deck.first?.id == card.id else { return }
        ratings = foundRatings
    }

    // MARK: - Description

    /// The card's copy, written exactly like a hero's: the title's logo, the
    /// claim under it, then facts, scores, the storyline and the controls in
    /// the same fixed box a title page and Home's marquee use.
    private func description(of item: MediaItem) -> some View {
        HeroCopyBlock(item: item, fallbackLogo: details?.logoURL,
                      pending: details == nil, tagline: details?.tagline,
                      taglineMaxWidth: 400) {
            factsLine(of: item)
            ratingsCrown(of: item)
            overviewLine(of: item)
            buttonsLine(of: item)
        }
        .foregroundStyle(.white)
    }

    /// "2026 · Movie · 2h 25min · Thriller · Crime" — the hero's facts line,
    /// with the kind spelled out because the deck mixes films and shows.
    private func factsLine(of item: MediaItem) -> some View {
        HStack(spacing: 10) {
            Text(metaLine(of: item))
                .font(.callout.weight(.medium))
                .opacity(0.92)
                .lineLimit(2)
            if details == nil { SkeletonBar(width: 140) }
        }
    }

    private func metaLine(of item: MediaItem) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        parts.append(item.type.displayName)
        if let runtime = details?.runtimeMinutes, runtime > 0 {
            parts.append(Duration.seconds(runtime * 60)
                .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        if let seasons = details?.seasonCount {
            parts.append(String(format: String(localized: "%d seasons", bundle: .module), seasons))
        }
        let genres = details?.genres ?? item.genreIds.compactMap {
            Genres.name(for: $0, type: item.type)
        }
        parts.append(contentsOf: genres.prefix(3))
        parts.append(contentsOf: details?.countryNames ?? [])
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func overviewLine(of item: MediaItem) -> some View {
        let overview = details?.overview ?? item.overview
        if let overview, !overview.isEmpty {
            Text(overview)
                .font(.callout)
                .lineSpacing(2)
                .lineLimit(4)
                .opacity(0.85)
        }
    }

    /// The hero's controls: the trailer under YouTube's own mark, and the way
    /// into the full page.
    private func buttonsLine(of item: MediaItem) -> some View {
        HStack(spacing: 10) {
            Button {
                showTrailer = true
            } label: {
                Label {
                    Text("Trailer", bundle: .module)
                } icon: {
                    BrandMark(name: "youtube", height: 13, fallbackSymbol: "play.fill",
                              fallbackTint: .white)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.25))
            .disabled(trailerKey == nil)
            .keyboardShortcut("t", modifiers: [])

            Button {
                openTitle(TitleSelection(items: [item], index: 0))
            } label: {
                HStack(spacing: 4) {
                    Text("More", bundle: .module)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.upArrow, modifiers: [])
        }
        .controlSize(.large)
        .padding(.top, 2)
    }

    /// The crown: scores from every service we can reach, in the hero's
    /// inline cut rather than a set of pills of the Quiz's own.
    private func ratingsCrown(of item: MediaItem) -> some View {
        ScoreStrip(scores: ServiceScore.row(tmdb: details?.rating ?? item.rating,
                                            votes: details?.voteCount ?? item.voteCount,
                                            tmdbURL: details?.tmdbURL,
                                            external: ratings,
                                            imdbURL: details?.imdbURL)
                       .filter { $0.value != nil },
                   style: .inline, showsVotes: true, mono: true)
            .animation(.easeOut(duration: 0.25), value: ratings?.value(for: .imdb))
    }

    // MARK: - Backdrop

    /// The current card's backdrop, blurred, drifting with the drag.
    /// Order matters: overscan first, blur second, clip last — anything else
    /// smears the edges into visible bands.
    private var backdrop: some View {
        let progress = min(1, abs(drag.width + flyOff * 300) / 300)
        return Color.black
            .overlay {
                // The upcoming card sits underneath; the current one fades
                // out with the swipe, so the background glides instead of
                // cutting when the card commits.
                if let next = deck.dropFirst().first {
                    blurredArt(of: next)
                }
                if let card {
                    blurredArt(of: card)
                        .offset(x: drag.width * 0.08)
                        .opacity(1 - Double(progress) * 0.9)
                        .transition(.opacity)
                        .id(card.id)
                }
            }
            .overlay(Color.black.opacity(0.45))
            .clipped()
            .animation(.easeOut(duration: 0.35), value: card?.id)
            .ignoresSafeArea()
    }

    private func blurredArt(of item: MediaItem) -> some View {
        RemoteImage(url: item.backdropURL ?? item.displayLargePosterURL)
            .scaleEffect(1.4)
            .blur(radius: 42, opaque: true)
    }

    // MARK: - Deck

    private func deckStack(layout: QuizLayout, size: CGSize) -> some View {
        let cardWidth = layout.cardWidth
        let cardHeight = layout.cardHeight
        let visible = Array(deck.prefix(3))
        // Three fixed slots, back to front, whose CONTENT changes as the deck
        // moves. A ForEach over the deck put the card joining the bottom on
        // top of the one above it for a frame — a new view is drawn last and
        // enters animating from its unmodified geometry, and `zIndex` did not
        // hold it back.
        return ZStack {
            if visible.count > 2 { slot(visible[2], depth: 2, width: cardWidth, height: cardHeight, size: size) }
            if visible.count > 1 { slot(visible[1], depth: 1, width: cardWidth, height: cardHeight, size: size) }
            if let top = visible.first { slot(top, depth: 0, width: cardWidth, height: cardHeight, size: size) }
        }
        .frame(height: cardHeight + QuizLayout.fan)
    }

    private func slot(_ item: MediaItem, depth: Int,
                      width: CGFloat, height: CGFloat, size: CGSize) -> some View {
        // Where this card sits in the stack right now — a fraction while the
        // top card is on its way out, so the whole deck rises together.
        let place = max(0, CGFloat(depth) - promote)
        return QuizCard(item: item, stampAmount: depth == 0 ? stampAmount : 0)
            .frame(width: width, height: height)
            .scaleEffect(1 - 0.06 * place)
            .offset(y: place * 16)
            .opacity(1 - 0.4 * max(0, min(1, place - 1)))
            .offset(depth == 0 ? drag : .zero)
            .offset(x: depth == 0 ? flyOff * (size.width * 0.85) : 0)
            .rotationEffect(.degrees(depth == 0 ? Double(drag.width + flyOff * 300) / 18 : 0),
                            anchor: .bottom)
            .gesture(depth == 0 ? dragGesture : nil)
            .onTapGesture {
                if depth == 0 { openTitle(TitleSelection(items: [item], index: 0)) }
            }
            .pointerStyle(depth == 0 ? .link : .default)
    }

    /// -1…1: how strongly the NOPE/LIKE stamp shows on the top card.
    private var stampAmount: CGFloat {
        max(-1, min(1, (drag.width + flyOff * 300) / 130))
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                if value.translation.width > 130 {
                    swipe(liked: true)
                } else if value.translation.width < -130 {
                    swipe(liked: false)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        drag = .zero
                    }
                }
            }
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 26) {
            roundButton(systemImage: "arrow.uturn.backward", size: 44, tint: .white.opacity(0.55)) {
                undo()
            }
            .disabled(session.history.isEmpty)
            .keyboardShortcut("z", modifiers: [])

            roundButton(systemImage: "xmark", size: 60, tint: .white.opacity(0.85),
                        amount: max(0, -buttonPressure)) {
                swipe(liked: false)
            }
            .disabled(card == nil)
            .keyboardShortcut(.leftArrow, modifiers: [])

            roundButton(systemImage: "heart.fill", size: 60, tint: .pink,
                        amount: max(0, buttonPressure)) {
                swipe(liked: true)
            }
            .disabled(card == nil)
            .keyboardShortcut(.rightArrow, modifiers: [])

            NavigationLink(value: QuizHistoryRef()) {
                roundFace(systemImage: "clock.arrow.circlepath", size: 44,
                          tint: .white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help(Text("Quiz History", bundle: .module))
        }
    }

    /// What the deck currently holds, when it is not the endless feed: the
    /// collection it was dealt from, and a button that says in words what it
    /// does — deal random cards again. It sits under the swipe buttons,
    /// where the deck's own controls are, and it is never a bare glyph: a ✕
    /// beside a name reads as "close", which is not what this is.
    /// Out of a collection deck and back to the page that dealt it.
    ///
    /// A corner ✕ and the action bar's ✕ are NOT the same button, so they do
    /// not look alike: this one is small, dim and pinned to the corner where
    /// a close lives, while "skip this card" is the big white disc in the
    /// middle. It names its destination in a tooltip, because a bare glyph
    /// cannot say which of the two it is.
    @ViewBuilder
    private var closeDeckButton: some View {
        if let onClose, let name = session.source.name {
            Button(action: onClose) {
                roundFace(systemImage: "xmark", size: 30, tint: .white.opacity(0.65))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help(Text(String(format: String(localized: "Back to %@", bundle: .module), name)))
            .accessibilityLabel(Text(String(format: String(localized: "Back to %@", bundle: .module), name)))
            // Clear of the window's own title bar, which the detail column
            // runs underneath.
            .padding(.top, 34)
            .padding(.trailing, 28)
        }
    }

    @ViewBuilder
    private var deckSourceLine: some View {
        if let name = session.source.name {
            HStack(spacing: 10) {
                Text(String(format: String(localized: "Deck: %@", bundle: .module), name))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Button {
                    Task { await session.resumeFeed(config: config) }
                } label: {
                    Label {
                        Text("Random Cards", bundle: .module)
                    } icon: {
                        Image(systemName: "shuffle")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// -1 (skip) … 1 (like): what the two big buttons answer to. While the
    /// card is in hand that is the drag itself, so the ✕ and the ♥ light up
    /// under the thumb; while it flies off — sent by a click or an arrow key,
    /// where there is no drag to read — it is the kick, which springs back to
    /// rest after the next card lands.
    private var buttonPressure: CGFloat {
        kick != 0 ? kick : stampAmount
    }

    private func roundButton(systemImage: String, size: CGFloat, tint: Color,
                             amount: CGFloat = 0,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            roundFace(systemImage: systemImage, size: size, tint: tint, amount: amount)
        }
        .buttonStyle(.plain)
    }

    /// The glass disc every action-bar control wears — shared so the history
    /// link matches the swipe buttons exactly. `amount` (0…1) is how strongly
    /// this button is being chosen right now: it swells, fills with its own
    /// tint and throws a glow, so the card's departure and the button that
    /// caused it are one movement.
    private func roundFace(systemImage: String, size: CGFloat, tint: Color,
                           amount: CGFloat = 0) -> some View {
        let lit = max(0, min(1, amount))
        return Image(systemName: systemImage)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .background(.white.opacity(0.06), in: Circle())
            .overlay(Circle().fill(tint.opacity(0.28 * lit)))
            .overlay(Circle().strokeBorder(glassRim, lineWidth: 1))
            .overlay(Circle().strokeBorder(tint.opacity(0.7 * lit), lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .shadow(color: tint.opacity(0.65 * lit), radius: 18 * lit)
            .scaleEffect(1 + 0.22 * lit)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: lit)
    }

    private func swipe(liked: Bool) {
        guard let card else { return }
        withAnimation(.easeIn(duration: 0.22)) {
            flyOff = liked ? 1.2 : -1.2
            promote = 1
            // The button that sent the card leaves with it, lit at full.
            kick = liked ? 1 : -1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            session.history.append(QuizSession.Decision(item: card, liked: liked))
            QuizVerdict.log(card, liked: liked, in: context)
            if liked { addToPicks(card) }
            // Strictly instant, all in one go. Animated, the top slot — now
            // holding the NEXT card — sprang back from off-screen where the
            // departing card left it, and for those frames the card visible
            // in the middle was the one BELOW it. That was the blink.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                session.deck.removeFirst()
                drag = .zero
                flyOff = 0
                // The deck has actually moved up now; the fraction that stood
                // in for it goes back to zero in the same frame.
                promote = 0
            }
            // Outside the instant transaction: the card is gone in one
            // frame, but the button it left under eases back to rest.
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { kick = 0 }
            if session.deck.count < 6 {
                Task { await session.refill(config: config) }
            }
        }
    }

    private func undo() {
        guard let last = session.history.popLast() else { return }
        if last.liked { removeFromPicks(last.item) }
        QuizVerdict.undoLast(last.item, in: context)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            session.deck.insert(last.item, at: 0)
        }
    }

    // MARK: - Picks list

    private func picksList() -> WatchList {
        let name = String(localized: "Quiz Picks", bundle: .module)
        let predicate = #Predicate<WatchList> { $0.name == name }
        if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
            return existing
        }
        let list = WatchList(name: name, symbol: "sparkles")
        context.insert(list)
        return list
    }

    private func addToPicks(_ item: MediaItem) {
        let list = picksList()
        let saved = Library.savedTitle(for: item, in: context)
        if !saved.lists.contains(where: { $0.persistentModelID == list.persistentModelID }) {
            saved.lists.append(list)
        }
        try? context.save()
    }

    private func removeFromPicks(_ item: MediaItem) {
        guard let saved = Library.existingTitle(for: item, in: context) else { return }
        let list = picksList()
        saved.lists.removeAll { $0.persistentModelID == list.persistentModelID }
        Library.pruneIfOrphaned(saved, in: context)
        try? context.save()
    }

}

/// The live Quiz run: the deck on screen, what has been swiped, and the feed
/// that keeps dealing. Owned by `RootView` so switching sidebar sections (and
/// so tearing down `QuizView`) does not restart the quiz.
@MainActor
public final class QuizSession: ObservableObject {
    struct Decision {
        let item: MediaItem
        let liked: Bool
    }

    /// Where the cards on the table came from. The random feed tops itself
    /// up forever; a collection dealt from a library page is a finite deck
    /// and must never be padded with strangers.
    enum Source: Equatable {
        case feed
        case collection(String)

        var name: String? {
            if case .collection(let name) = self { return name }
            return nil
        }
    }

    @Published var deck: [MediaItem] = []
    @Published var loading = false
    @Published private(set) var source: Source = .feed
    var history: [Decision] = []
    private let feed = QuizFeed()

    public init() {}

    /// First deal of the session; a no-op once cards are on the table.
    func refillIfNeeded(config: TonightConfig) async {
        guard deck.isEmpty else { return }
        await refill(config: config)
    }

    /// Deal a library page's titles instead of the feed's. The run starts
    /// over: undo history from the previous deck would put a stranger's card
    /// back on top of this one.
    func deal(_ items: [MediaItem], from name: String) {
        deck = items.filter { $0.posterPath != nil || $0.backdropPath != nil }
        history = []
        source = .collection(name)
    }

    /// Back to the endless random deck — the way out of a collection, and
    /// what "Deal again" means once one has run dry.
    func resumeFeed(config: TonightConfig) async {
        source = .feed
        deck = []
        history = []
        await refill(config: config)
    }

    func refill(config: TonightConfig) async {
        // A collection is exactly as long as it is.
        guard source == .feed else { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let tmdb = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
        let fresh = await feed.next(tmdb: tmdb)
        deck += fresh.filter { candidate in !deck.contains { $0.id == candidate.id } }
    }
}

/// Where the cards come from. Today: random pages of TMDB discover, movies
/// and series mixed, shuffled, never repeating within a session. Swap this
/// type's guts later for taste-driven feeds.
@MainActor
final class QuizFeed {
    private var seen = Set<String>()

    func next(tmdb: TMDBService) async -> [MediaItem] {
        var filter = DiscoverFilter(type: Bool.random() ? .movie : (Bool.random() ? .movie : .tv))
        filter.sort = .popularity
        let page = Int.random(in: 1...25)
        guard let items = try? await tmdb.discover(filter, page: page) else { return [] }
        let fresh = items
            .filter { $0.posterPath != nil && $0.backdropPath != nil }
            .filter { seen.insert($0.id).inserted }
        return fresh.shuffled()
    }
}

/// One deck card: full-bleed poster, bottom scrim with the essentials, and
/// the LIKE/NOPE stamps that follow the drag.
private struct QuizCard: View {
    let item: MediaItem
    /// -1 (full NOPE) … 1 (full LIKE)
    var stampAmount: CGFloat = 0

    var body: some View {
        RemoteImage(url: item.displayLargePosterURL)
            .overlay(alignment: .topLeading) {
                stamp(text: "LIKE", color: .green, amount: stampAmount)
                    .rotationEffect(.degrees(-12))
                    .padding(18)
            }
            .overlay(alignment: .topTrailing) {
                stamp(text: "NOPE", color: .red, amount: -stampAmount)
                    .rotationEffect(.degrees(12))
                    .padding(18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
    }

    private func stamp(text: String, color: Color, amount: CGFloat) -> some View {
        Text(verbatim: text)
            .font(.system(size: 30, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: 4))
            .opacity(Double(max(0, min(1, amount))))
    }
}

// MARK: - Layout

/// The deck sized to the window — its HEIGHT included.
///
/// The card used to take its size from the width alone (`width * 1.5`), so a
/// short window kept a full-height deck and pushed the ✕ / ♥ row off the
/// bottom of the page, out of reach and with no way to scroll to it. Here the
/// buttons are what the window is measured for first: the deck gets what is
/// left, and below the height where the copy column and the deck can both
/// stand, the copy steps aside rather than the controls.
struct QuizLayout {
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    /// Air between the deck, the buttons and the window's edges.
    let gap: CGFloat
    let showsDescription: Bool

    /// The tallest button in the action row.
    static let actionBar: CGFloat = 60
    /// The two cards peeking out under the top one.
    static let fan: CGFloat = 34

    init(_ size: CGSize, extraChrome: CGFloat = 0) {
        let tight = size.height < 720
        gap = tight ? 16 : 30
        // Top padding, the gap over the buttons, bottom padding — plus the
        // buttons themselves, the fan under the deck, and whatever else the
        // page has put below the buttons.
        let chrome = gap * 3 + Self.actionBar + Self.fan + extraChrome
        let byWidth = min(max(280, size.width * 0.28), 380)
        let byHeight = max(180, size.height - chrome) / 1.5
        cardWidth = max(120, min(byWidth, byHeight))
        cardHeight = cardWidth * 1.5
        // The copy block is a fixed box (`HeroCopy.belowLogo` and the logo
        // above it): under this it no longer fits beside anything, and it is
        // the part a swipe deck can do without.
        showsDescription = size.height >= 560
    }
}
