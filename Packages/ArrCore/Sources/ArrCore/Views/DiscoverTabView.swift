import SwiftUI

public struct DiscoverTabView: View {
    var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let radarrAvailable: Bool
    /// True while the agent is working on a turn. The top-up round IS a chat
    /// turn, so this is the honest answer to "are we still looking?" — far
    /// better than a fixed timer, which either cuts the wait short or leaves a
    /// spinner up long after the agent gave up.
    var moreInFlight: Bool = false
    /// True while another overlay (DetailView / SearchAddPanel) is drawn on
    /// top of the parked deck. Parking disables clicks, but keyboard focus is
    /// its own channel — without this the arrow keys kept swiping cards
    /// underneath the detail view.
    var isObscured: Bool = false
    let onClose: () -> Void
    let onCancelLoading: () -> Void
    let onRequestMore: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false
    /// In-flight state for the empty-state "More picks like these" button — the
    /// appended round comes back via a chat round-trip, so the button shows a
    /// spinner until fresh cards land (or a timeout re-enables it for a retry).
    @State private var requestingMore: Bool = false
    /// `sessionTotal` at the moment we last kicked off a background top-up.
    /// The round-trip only bumps `sessionTotal` when items actually land, so
    /// comparing against it both throttles the trigger (one request per
    /// deck-tail) and re-arms it as soon as the deck genuinely grew.
    @State private var prefetchedAtTotal: Int?
    /// Escape hatch for a round that never resolves. Held so a new request
    /// can cancel the previous one's timer instead of racing it.
    @State private var moreTimeout: Task<Void, Never>?
    /// True once we've automatically re-asked for a round that came back
    /// without growing the deck. Cleared the moment cards actually land, so
    /// each dry tail gets exactly one silent retry and never a loop.
    @State private var emptyRoundRetried = false
    /// Trailer for the card on top of the deck, resolved as it comes up so the
    /// button only appears when there's something to play.
    @State private var trailer: TrailerReel?
    /// Card id `trailer` belongs to. While it lags behind the top card the
    /// button is still on screen (see `resolveTrailer`) but inert — it would
    /// otherwise play the PREVIOUS card's clip.
    @State private var trailerCardId: String?
    /// The clip on screen. Same shared-session presentation every other trailer
    /// surface uses (rendered by the surface root), so the Quiz keeps no
    /// player layout of its own.
    @ObservedObject private var trailerSession = TrailerSession.shared
    /// Keyboard focus for the deck. Arrow keys only reach `onKeyPress` while
    /// something is focused, and the deck is the only thing on screen worth
    /// focusing — the tab content behind it is parked and disabled while the
    /// overlay is up, so there is nothing to fight with over the keys.
    @FocusState private var deckFocused: Bool
    /// A verdict is playing out. The skip animation runs for 550 ms before the
    /// card is actually dropped, and a second verdict inside that window would
    /// advance the deck twice while the user saw one card leave — trivially
    /// easy to do by holding the arrow key down.
    @State private var verdictInFlight = false
    /// Artwork the incoming-backdrop layer is pinned to for the whole verdict.
    /// It cannot be read live from `queue.first`: `viewModel` is `@Observable`
    /// and `dragOffset` is `@State`, so the deck can advance a frame before the
    /// offset resets. In that frame a live lookup already points at the card
    /// AFTER the next one and paints it at full opacity — the one-frame flash.
    /// Pinned, the layer still shows the card that just became current, which
    /// is pixel-identical to the layer beneath it, so the seam is invisible.
    @State private var pinnedIncomingBackdrop: URL?

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                radarrAvailable: Bool,
                moreInFlight: Bool = false,
                isObscured: Bool = false,
                onClose: @escaping () -> Void,
                onCancelLoading: @escaping () -> Void = {},
                onRequestMore: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.radarrAvailable = radarrAvailable
        self.moreInFlight = moreInFlight
        self.isObscured = isObscured
        self.onClose = onClose
        self.onCancelLoading = onCancelLoading
        self.onRequestMore = onRequestMore
    }

    public var body: some View {
        if let phase = viewModel.loadPhase {
            QuizLoadingView(phase: phase, startedAt: viewModel.loadStartedAt, onCancel: onCancelLoading)
        } else {
            swipeSurface
        }
    }

    // MARK: - Immersive swipe surface

    /// Full-bleed poster deck. The card fills the whole popover; the back
    /// button + mood chip float over the top edge, and the two round verdict
    /// buttons (✕ dislike, + add) float over the bottom edge.
    ///
    /// Split into three stages — chrome, keyboard, deck lifecycle — because as
    /// one chain it is more than the type-checker will take in reasonable time.
    private var swipeSurface: some View {
        deckWithKeyboard
            // Top up the deck while the user is still swiping rather than
            // after they've hit the wall. The refill is a chat round-trip
            // (see `requestMore`), so waiting for the empty state meant
            // staring at a button and a spinner for several seconds; starting
            // it on the second-to-last card usually means the cards are just
            // there. The empty state keeps its button as the fallback for when
            // the round-trip is slow or never lands.
            .onChange(of: viewModel.queue.count) { _, remaining in
                guard remaining <= 1 else { return }
                prefetchMoreIfNeeded()
            }
            // Items landed — the round is over, whatever the timer thinks.
            .onChange(of: viewModel.sessionTotal) { _, _ in
                finishRequestingMore()
                emptyRoundRetried = false
            }
            // The agent stopped working. Either it produced picks (handled
            // above) or it answered without calling the tool — either way
            // there is nothing left to wait for, so stop claiming there is.
            .onChange(of: moreInFlight) { wasInFlight, nowInFlight in
                guard wasInFlight, !nowInFlight else { return }
                finishRequestingMore()
                // If we skipped a top-up because the agent was mid-turn, this
                // is the moment to take it. Can't loop: `prefetchedAtTotal`
                // only re-arms once items actually land.
                if viewModel.queue.count <= 1 { prefetchMoreIfNeeded() }
                retryEmptyRoundIfNeeded()
            }
            .onAppear { repinIncomingBackdrop() }
            .onChange(of: viewModel.current?.dedupKey) { _, _ in repinIncomingBackdrop() }
            .onChange(of: viewModel.queue.first?.dedupKey) { _, _ in repinIncomingBackdrop() }
            .onChange(of: verdictInFlight) { _, inFlight in
                if !inFlight { repinIncomingBackdrop() }
            }
            .onDisappear { moreTimeout?.cancel() }
    }

    /// The deck plus its chrome: scrim, back button, verdict buttons, trailer.
    private var decoratedDeck: some View {
        swipeBackground
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(blurredBackdrop)
            .overlay(alignment: .top) {
                // The deck is a full-bleed poster with no top gradient of its
                // own (only a bottom scrim, in DiscoverCardView), so the bare
                // back chevron + mood chip need a subtle top darken to stay
                // legible over bright artwork. Only while a card is showing.
                if viewModel.current != nil { topLegibilityScrim }
            }
            .overlay(alignment: .top) { floatingTopChrome }
            .overlay(alignment: .bottom) {
                if viewModel.current != nil {
                    actionButtons
                }
            }
            // Right-click (macOS) / long-press (iOS) on the card: the explicit
            // permanent "no". The ambient ✕ is only ever a cooldown; this is
            // the one action that bans a title for good, so it hides behind a
            // deliberate gesture instead of sharing the button row.
            .contextMenu {
                if viewModel.current != nil {
                    Button(role: .destructive, action: handleVeto) {
                        Label {
                            Text("discover.veto.button", bundle: .module)
                        } icon: {
                            Image(systemName: "hand.thumbsdown")
                        }
                    }
                }
            }
            .task(id: viewModel.current?.id) { await resolveTrailer(for: viewModel.current) }
    }

    /// Veto: same fly-off as a skip — the card leaves the same way, only the
    /// memory of it differs.
    private func handleVeto() {
        guard !verdictInFlight else { return }
        verdictInFlight = true
        withAnimation(.easeOut(duration: 0.55)) {
            dragOffset = CGSize(width: -1000, height: 0)
        }
        Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            viewModel.veto()
            dragOffset = .zero
            isDragging = false
            verdictInFlight = false
        }
    }

    /// Keyboard verdicts, mapped onto the swipe they mirror: ← throws the card
    /// left exactly like the ✕ button, → opens the add card like a right swipe.
    /// Only the top card is ever addressed, so there is no selection to move
    /// and nothing else to bind.
    private var deckWithKeyboard: some View {
        decoratedDeck
            .focusable(viewModel.current != nil && !isObscured)
            .focusEffectDisabled()
            .focused($deckFocused)
            .onKeyPress(.leftArrow) { keyVerdict(skip: true) }
            .onKeyPress(.rightArrow) { keyVerdict(skip: false) }
            .onAppear { deckFocused = true }
            // Focus follows the obscuring overlay: released the moment a
            // detail/add surface opens on top, restored when the deck is
            // front again.
            .onChange(of: isObscured) { _, obscured in deckFocused = !obscured }
            // Focus comes back with the deck: after a card is added the panel
            // closes onto a new top card, and after the trailer is dismissed the
            // deck is live again — in both cases the keys should just work
            // without the user clicking the poster first.
            .onChange(of: viewModel.current?.id) { _, _ in deckFocused = true }
            .onChange(of: trailerSession.key) { _, presented in
                if presented == nil { deckFocused = true }
            }
    }

    /// Fires one background top-up per deck-tail. Deliberately reuses
    /// `requestingMore`: if the deck does run dry before the round-trip
    /// lands, the empty-state button is already showing its spinner and
    /// disabled, so the user can't fire a second identical request.
    private func prefetchMoreIfNeeded() {
        // Same preconditions as the empty-state button — without an LLM the
        // request goes nowhere, and without engagement it has no signal to
        // feed back ("more like WHAT?").
        guard llmAvailable,
              viewModel.current != nil,
              viewModel.hasSessionEngagement,
              !isLookingForMore,
              prefetchedAtTotal != viewModel.sessionTotal else { return }
        // The host drops the request when the agent is mid-turn, so firing
        // now would leave a "looking for more" state with nothing behind it.
        // `onChange(of: moreInFlight)` retries the moment the agent frees up.
        guard !moreInFlight else { return }
        prefetchedAtTotal = viewModel.sessionTotal
        requestMore()
    }

    /// A top-up turn that ends without the deck growing is NOT the same thing
    /// as an exhausted deck — the round can come back as titles the deck
    /// already showed (dropped on arrival), or as prose with no tool call at
    /// all. Both used to dump the user straight on "No more cards" even though
    /// tapping the button by hand right after found picks. So take that retry
    /// automatically, exactly once per dry tail, and only then call it done.
    private func retryEmptyRoundIfNeeded() {
        guard llmAvailable,
              viewModel.current == nil,
              viewModel.queue.isEmpty,
              viewModel.hasSessionEngagement,
              !emptyRoundRetried else { return }
        emptyRoundRetried = true
        requestMore()
    }

    /// True whenever a top-up is genuinely outstanding — either we just asked,
    /// or the agent is still working on the turn.
    private var isLookingForMore: Bool { requestingMore || moreInFlight }

    /// Shared by the background top-up and the empty-state button so both
    /// paths get the same in-flight feedback.
    ///
    /// The in-flight state ends when the WORK ends — `moreInFlight` going
    /// quiet, or items actually landing — not on a stopwatch. It used to be a
    /// flat 12 s timer, which was survivable while the timer started on a
    /// button tap, and broke the moment the background top-up started it one
    /// or two cards earlier: by the time the deck ran dry most of the budget
    /// was already spent, so the "looking for more" state expired mid-flight
    /// and dumped the user back on the end-of-deck screen while the round was
    /// still running. The remaining timeout is only a stuck-state escape.
    private func requestMore() {
        moreTimeout?.cancel()
        requestingMore = true
        onRequestMore()
        moreTimeout = Task {
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            requestingMore = false
        }
    }

    /// Ends the in-flight state and cancels its escape timer.
    private func finishRequestingMore() {
        moreTimeout?.cancel()
        moreTimeout = nil
        requestingMore = false
    }

    /// Gradient darken behind the top chrome — transparent by ~90pt down so it
    /// never touches the card's own bottom metadata. Kept light (≈0.3) so it
    /// reads as "just enough contrast for the chevron", not a heavy banner.
    private var topLegibilityScrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.3), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 90)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    /// The current card's own artwork, blown up past the edges and blurred, so
    /// the letterboxing a phone's aspect ratio leaves around a 2:3 poster reads
    /// as part of the card instead of dead black.
    ///
    /// The `.id(url)` is what makes the cross-fade possible: without it every
    /// card reuses ONE `RemotePoster`, so SwiftUI sees an image swap inside a
    /// stable view — nothing to transition, and the backdrop cut hard. Keyed by
    /// url the old layer is removed and the new one inserted, which `.opacity`
    /// can actually blend. Black sits underneath so the outgoing layer fades to
    /// the same ground the empty state uses.
    private var blurredBackdrop: some View {
        ZStack {
            Color.black
            if let url = viewModel.current?.result.posterURL {
                // Deliberately NO `.id(url)`. Keying by url remounts the view,
                // which resets `RemotePoster`'s `@State image` to nil and paints
                // one frame of placeholder before the (cached) artwork lands —
                // that was the flash at the end of every verdict. Reused, the
                // poster keeps the previous image on screen until the new one
                // is decoded, so the swap has no blank frame at all.
                backdropLayer(url: url)
            }
            // The incoming card's scenery, revealed by the swipe itself rather
            // than by a transition that fires later: at rest it is invisible,
            // and it bleeds through in step with the finger.
            if let next = pinnedIncomingBackdrop {
                // Same reasoning as above: no `.id`, so this layer is reused
                // across cards instead of remounting behind a zero opacity.
                backdropLayer(url: next)
                    .opacity(incomingBackdropOpacity)
            }
        }
        .ignoresSafeArea()
    }

    /// How much of the next card's backdrop shows through, driven straight off
    /// the drag. Deliberately NOT a `.transition` or an `.animation(value:)`:
    /// both can only start once the deck has already advanced, which is 550 ms
    /// after the verdict — the scenery then changed as an afterthought. Reading
    /// `dragOffset` instead means the blend tracks the finger while dragging
    /// and keeps going by itself during the fly-off, because the verdict
    /// handlers animate that same offset out to the edge.
    ///
    /// 200 pt (not the 90 pt the card's own verdict tint uses) so a hesitant
    /// drag only hints at the change; the fly-off carries the rest.
    private var incomingBackdropOpacity: Double {
        guard isDragging || verdictInFlight else { return 0 }
        let travelled = -dragOffset.width
        guard travelled > 0 else { return 0 }
        return Double(min(1, travelled / 200))
    }

    /// Re-pin once the deck is settled — never mid-verdict, which is the whole
    /// point of pinning.
    private func repinIncomingBackdrop() {
        guard !verdictInFlight, !isDragging else { return }
        pinnedIncomingBackdrop = viewModel.queue.first?.result.posterURL
    }

    private func backdropLayer(url: URL) -> some View {
        GeometryReader { proxy in
            RemotePoster(
                url: url,
                apiKey: nil,
                size: proxy.size,
                cornerRadius: 0,
                fallbackSymbol: "film",
                fill: true,
                showsLoadingIndicator: false
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Scale first, then blur: blurring at frame size leaves a soft
            // transparent rim where the filter samples past the edge.
            .scaleEffect(1.35)
            .blur(radius: 42, opaque: true)
            .overlay(Color.black.opacity(0.45))
            .clipped()
        }
    }

    @ViewBuilder
    private var swipeBackground: some View {
        if viewModel.current != nil {
            cardStack
        } else {
            emptyStackState
        }
    }

    private var floatingTopChrome: some View {
        ZStack {
            HStack {
                // The same bare-chevron control every other surface uses
                // (DetailView / Search / Season / Episode) — not a one-off glass
                // circle — so the back affordance is consistent app-wide. The
                // top scrim above keeps it readable over the poster.
                FloatingBackButton(action: onClose)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    /// The two round, icon-only verdict buttons. ✕ = skip to the next card
    /// (neutral — direction-free, unlike the old ⏩ whose right-arrows fought
    /// the card flying LEFT), + = add to collection (accent). Each lifts as
    /// the drag heads its way; colours mirror the swipe tint.
    private var actionButtons: some View {
        // Center: ONLY the two verdicts, a stable pair that never moves.
        // Edges carry the helpers — rewind on the left (corrects a decision),
        // trailer on the right (informs one) — so neither's appearance ever
        // shoves the main pair sideways.
        ZStack {
            centeredVerdictButtons
            HStack {
                if viewModel.canUndoSkip {
                    GlassCircleButton(
                        systemName: "arrow.uturn.backward",
                        tint: .secondary,
                        diameter: Layout.buttonDiameter * 0.72,
                        accessibilityKey: "discover.undo.button",
                        action: handleUndo
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                Spacer()
                // Rendered only once a clip is known: a permanently dead
                // button would be worse than one that arrives when ready.
                if trailer != nil {
                    GlassCircleButton(
                        assetName: "brand-youtube",
                        // Smaller than the two verdicts on purpose: skip and
                        // add are the decision, the trailer only helps you
                        // make it.
                        diameter: Layout.buttonDiameter * 0.72,
                        accessibilityKey: "discover.trailer.button",
                        action: {
                            // Ignore taps aimed at a clip we haven't resolved
                            // for THIS card yet.
                            guard trailerCardId == viewModel.current?.id,
                                  let trailer else { return }
                            withAnimation(.smooth(duration: 0.2)) { trailerSession.present(trailer) }
                        }
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, Layout.buttonBottomPadding)
    }

    private var centeredVerdictButtons: some View {
        HStack(spacing: 30) {
            GlassCircleButton(
                systemName: "xmark",
                tint: .secondary,
                extraScale: 0.16 * leftDragProgress,
                accessibilityKey: "Skip",
                action: handleSkip
            )
            GlassCircleButton(
                systemName: "plus",
                tint: .accentColor,
                extraScale: 0.16 * rightDragProgress,
                accessibilityKey: "discover.addToLibrary.button",
                action: handleAdd
            )
        }
    }

    /// Resolves the top card's trailer. `foreignId` is the arr's own foreign
    /// key — a TMDB movie id on movie cards, a TVDB series id on show cards
    /// (Sonarr lookup is what builds them) — so each kind takes its own route.
    private func resolveTrailer(for item: DiscoverItem?) async {
        // The button deliberately STAYS while the next card resolves. Clearing
        // it here made it vanish and reappear between every two cards that both
        // have trailers — a blink, and a row of buttons resizing around it.
        withAnimation(.smooth(duration: 0.2)) {
            // The overlay is a different matter: a new card must never keep the
            // previous title's clip playing. Only OUR clip, though — a session
            // restored across a popover reopen belongs to whoever started it.
            if trailerSession.isShowing(trailer) { trailerSession.dismiss() }
        }
        guard let item, let foreignId = Int(item.result.foreignId), foreignId > 0 else {
            withAnimation(.smooth(duration: 0.2)) { trailer = nil }
            trailerCardId = nil
            return
        }
        let found: TrailerReel?
        switch item.kind {
        case .movie:
            found = await TrailerProvider.movieReel(
                radarrTrailerId: nil, tmdbId: foreignId, configStore: ConfigStore.shared
            )
        case .show:
            found = await TrailerProvider.seriesReel(
                tmdbId: nil, tvdbId: foreignId, configStore: ConfigStore.shared
            )
        }
        // The deck may have moved on while TMDB was answering.
        guard viewModel.current?.id == item.id else { return }
        trailerCardId = found == nil ? nil : item.id
        withAnimation(.smooth(duration: 0.2)) { trailer = found }
    }

    private var rightDragProgress: CGFloat { max(0, min(1, dragOffset.width / 90)) }
    private var leftDragProgress: CGFloat { max(0, min(1, -dragOffset.width / 90)) }

    // MARK: - Card stack

    private var cardStack: some View {
        let stack = visibleStack.enumerated().map { ($0, $1) }
        return GeometryReader { proxy in
            ZStack {
                ForEach(stack.reversed(), id: \.1.id) { (idx, item) in
                    let isTop = (idx == 0)
                    DiscoverCardStackItem(
                        item: item,
                        isTop: isTop,
                        cardWidth: proxy.size.width,
                        cardHeight: proxy.size.height,
                        dragOffset: dragOffset,
                        bottomInset: Layout.cardBottomInset,
                        animationKey: viewModel.current?.dedupKey,
                        gesture: isTop ? dragGesture : nil,
                        onMore: { openCard(for: item) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var visibleStack: [DiscoverItem] {
        let curr = viewModel.current.map { [$0] } ?? []
        // One peek card is enough for a seamless swap — it sits hidden
        // behind the top card and scales up to fill as the top flies off.
        let peek = Array(viewModel.queue.prefix(1))
        return curr + peek
    }

    // MARK: - Gestures / verdicts

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if !isDragging { isDragging = true }
                dragOffset = value.translation
            }
            .onEnded { value in
                let threshold: CGFloat = 90
                if value.translation.width > threshold {
                    // Right = "I want this" → open the add-to-collection card.
                    // Does not advance — a cancelled add returns to this card.
                    handleAdd()
                } else if value.translation.width < -threshold {
                    // Left = skip → next card (the only action that advances).
                    handleSkip()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        dragOffset = .zero
                    }
                    isDragging = false
                }
            }
    }

    /// Right verdict: open the add-to-collection card for the current title.
    /// Records the pick (for the resume-card count) but deliberately does NOT
    /// advance the deck — whether the user adds or cancels, they return to the
    /// same card. The add/detail surface (owned → DetailView, fresh →
    /// SearchAddPanel) covers the popover while it's up.
    private func handleAdd() {
        guard let item = viewModel.current else { return }
        isDragging = false
        dragOffset = .zero
        viewModel.markPicked()
        openCard(for: item)
    }

    /// One arrow press. Ignored — rather than queued — while a card is already
    /// flying off or the trailer is up: a held-down arrow should not burn
    /// through the deck faster than the user can see it.
    private func keyVerdict(skip: Bool) -> KeyPress.Result {
        guard viewModel.current != nil, trailerSession.key == nil, !verdictInFlight,
              !isObscured else { return .ignored }
        if skip { handleSkip() } else { handleAdd() }
        return .handled
    }

    /// Rewind one skip. No fly-off choreography — the correction should feel
    /// like stepping back, not like a fourth swipe direction.
    private func handleUndo() {
        guard !verdictInFlight else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            viewModel.undoSkip()
        }
        dragOffset = .zero
        isDragging = false
    }

    /// Left verdict: skip to the next card. Fly the current card off to the
    /// left, THEN drop it and advance — the peek card scales up to fill
    /// instead of the next card sliding in.
    private func handleSkip() {
        guard !verdictInFlight else { return }
        verdictInFlight = true
        let flyDistance: CGFloat = 1000
        withAnimation(.easeOut(duration: 0.55)) {
            dragOffset = CGSize(width: -flyDistance, height: 0)
        }
        Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            viewModel.skip()
            dragOffset = .zero
            isDragging = false
            verdictInFlight = false
        }
    }

    /// Open the full movie/series card. `Więcej` calls this to *peek* (no
    /// advance); `handleAdd` calls it as the committing add action. Owned
    /// items land on DetailView (already in the library), fresh discoveries
    /// on the SearchAddPanel (the add flow). Both hide the deck while up and
    /// return to it on Back (PopoverContentView owns that swap).
    private func openCard(for item: DiscoverItem) {
        if let arrId = item.result.inLibraryArrId {
            DetailRequest.post(
                DetailRequest.syntheticItem(
                    source: item.result.source,
                    entityId: arrId,
                    title: item.result.title,
                    posterURL: item.result.posterURL,
                    posterRequiresAuth: false
                )
            )
        } else {
            SearchAddRequest.post(item.result, origin: .quiz)
        }
    }

    // MARK: - Empty stack

    /// Two states, never mixed. While a round is in flight the surface says
    /// exactly one thing — that we're looking — because a spinner buried
    /// inside a button, under a heading, next to two other actions reads as
    /// "something is happening somewhere" rather than as an answer. Once
    /// there's nothing in flight it becomes a plain end-of-deck message with a
    /// single primary action.
    ///
    /// The previous layout had four competing weights stacked in a row (icon,
    /// heading, a semibold link that outweighed the heading, then the CTA) and
    /// no sentence telling the user what had actually happened.
    @ViewBuilder
    private var emptyStackState: some View {
        VStack(spacing: 10) {
            Spacer()
            if isLookingForMore {
                ProgressView()
                Text("discover.lookingForMore.label", bundle: .module)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                WaitFactTicker(facts: WaitFacts.watching())
                    .padding(.horizontal, 24)
            } else {
                Image(systemName: "rectangle.stack.fill")
                    .scaledFont(size: 26, weight: .light)
                    .foregroundStyle(.tertiary)
                // Headline outranks everything below it now — it used to be
                // the smallest, faintest text on screen.
                Text("discover.noMoreCards.button", bundle: .module)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                Text("discover.thatsEverything.label", bundle: .module)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                // End of the deck is exactly where a mis-swipe hurts most —
                // the card is gone and nothing follows it. Offer the rewind
                // here too, not just under a live card.
                if viewModel.canUndoSkip {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            viewModel.undoSkip()
                        }
                    } label: {
                        Label {
                            Text("discover.undo.button", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .scaledFont(size: 12, weight: .medium)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                }
                // Needs the agent to fetch a fresh appended round (see
                // PopoverContentView.requestMoreQuizPicks), so only offer it when an
                // LLM is actually available — otherwise the tap goes nowhere.
                if llmAvailable && viewModel.hasSessionEngagement {
                    Button {
                        requestMore()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .scaledFont(size: 12, weight: .semibold)
                            Text("discover.morePicksLikeThese.button", bundle: .module)
                                .scaledFont(size: 13, weight: .semibold)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.top, 4)
                }
            }
            // Always last and always quiet — it's the way out, not an action
            // competing with the one the user probably wants.
            Button {
                onClose()
            } label: {
                Text("discover.backToMood.button", bundle: .module)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            // Setup hints explain an EMPTY deck.
            // While a round is in flight they'd contradict the one thing the
            // surface is saying, so they wait until it settles.
            if !isLookingForMore {
                if !radarrAvailable {
                    Text("discover.configureRadarrInSettings.tooltip",
                         bundle: .module)
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                }
                if !llmAvailable {
                    Text("discover.configureAnLlmProvider.tooltip",
                         bundle: .module)
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Layout constants

private enum Layout {
    static let buttonDiameter: CGFloat = 62
    /// 24 was tuned for a 400×600 popover, which has no home indicator. On a
    /// phone that puts the verdict buttons inside the system's swipe-up strip,
    /// so touches near their bottom edge get eaten.
    #if os(iOS)
    static let buttonBottomPadding: CGFloat = 44
    #else
    static let buttonBottomPadding: CGFloat = 24
    #endif
    /// Space the card reserves at its bottom so the metadata clears the
    /// floating action buttons.
    static let cardBottomInset: CGFloat = buttonDiameter + buttonBottomPadding + 20
}

// MARK: - Card stack item

/// A single card in the Quiz swipe deck plus its transform chain. The top
/// card carries the drag (offset / rotation); the lone peek card sits hidden
/// behind it and scales up to fill as the top flies off. Extracted from
/// `cardStack`'s `ForEach` so that closure stays trivial to type-check.
private struct DiscoverCardStackItem<G: Gesture>: View {
    let item: DiscoverItem
    let isTop: Bool
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let dragOffset: CGSize
    let bottomInset: CGFloat
    let animationKey: String?
    let gesture: G?
    let onMore: () -> Void

    var body: some View {
        let dragProgress = min(1, abs(dragOffset.width) / 90)
        let scale: CGFloat = isTop ? 1.0 : (0.94 + 0.06 * dragProgress)
        DiscoverCardView(item: item,
                         dragOffset: isTop ? dragOffset : .zero,
                         bottomInset: bottomInset,
                         onMore: onMore)
            .frame(width: cardWidth, height: cardHeight)
            .scaleEffect(scale)
            .offset(x: isTop ? dragOffset.width : 0,
                    y: isTop ? dragOffset.height * 0.3 : 0)
            .rotationEffect(isTop ? .degrees(Double(dragOffset.width / 22)) : .zero,
                            anchor: .center)
            .allowsHitTesting(isTop)
            .zIndex(isTop ? 1 : 0)
            .gesture(gesture)
            .animation(.spring(response: 0.32, dampingFraction: 0.85),
                       value: animationKey)
    }
}

// MARK: - Circular glass button

/// A round, icon-only clear-glass button over the poster deck. Used for the
/// swipe verdicts, the rewind and the trailer.
private struct GlassCircleButton: View {
    /// SF Symbol name. Ignored when `assetName` is set.
    var systemName: String = ""
    /// Brand mark from `ServiceIcons.xcassets`, drawn in its own colours
    /// instead of tinted — a YouTube glyph in monochrome is not the mark.
    var assetName: String?
    var tint: Color = .primary
    var diameter: CGFloat = Layout.buttonDiameter
    /// Transient scale added while a drag heads toward this button.
    var extraScale: CGFloat = 0
    let accessibilityKey: LocalizedStringKey
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            glyph
                .frame(width: diameter, height: diameter)
                .background(glassCircle)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect((hovering ? 1.07 : 1.0) + extraScale)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: extraScale)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(Text(accessibilityKey, bundle: .module))
        .help(Text(accessibilityKey, bundle: .module))
        #if os(macOS)
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }

    @ViewBuilder
    private var glyph: some View {
        if let assetName {
            Image(assetName, bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: diameter * 0.46)
        } else {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.40, weight: .bold))
                .foregroundStyle(tint)
        }
    }

    /// The clear glass variant — the one meant for controls floating over
    /// media. No tint, no painted rim: the poster stays the brightest thing on
    /// screen and the button is only the shape the light bends through. The
    /// card's own bottom scrim is the dimming layer clear glass asks for.
    private var glassCircle: some View {
        Circle()
            .fill(.clear)
            .glassEffect(.clear.interactive(), in: .circle)
    }
}
