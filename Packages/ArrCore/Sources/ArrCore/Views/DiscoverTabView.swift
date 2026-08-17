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
    let onRequestMore: (_ mood: String, _ kept: [DiscoverItem], _ skipped: [DiscoverItem]) -> Void

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
    @State private var trailerKey: String?
    /// Card id `trailerKey` belongs to. While it lags behind the top card the
    /// button is still on screen (see `resolveTrailer`) but inert — it would
    /// otherwise play the PREVIOUS card's clip.
    @State private var trailerKeyCardId: String?
    /// The clip on screen. Same full-surface presentation every other trailer
    /// surface uses, so the Quiz keeps no player layout of its own.
    @State private var presentedTrailer: String?
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

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                radarrAvailable: Bool,
                moreInFlight: Bool = false,
                isObscured: Bool = false,
                onClose: @escaping () -> Void,
                onRequestMore: @escaping (_ mood: String, _ kept: [DiscoverItem], _ skipped: [DiscoverItem]) -> Void = { _, _, _ in }) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.radarrAvailable = radarrAvailable
        self.moreInFlight = moreInFlight
        self.isObscured = isObscured
        self.onClose = onClose
        self.onRequestMore = onRequestMore
    }

    public var body: some View {
        swipeSurface
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
            .onDisappear { moreTimeout?.cancel() }
    }

    /// The deck plus its chrome: scrim, back button, verdict buttons, trailer.
    private var decoratedDeck: some View {
        swipeBackground
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .trailerOverlay(key: $presentedTrailer)
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
        Task { @MainActor in
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
            .onChange(of: presentedTrailer) { _, presented in
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
        onRequestMore(viewModel.moodText,
                      viewModel.sessionMatched,
                      viewModel.sessionSkipped)
        moreTimeout = Task { @MainActor in
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

    @ViewBuilder
    private var swipeBackground: some View {
        if viewModel.current != nil {
            cardStack
        } else if viewModel.isLoading {
            loadingState
        } else {
            emptyStackState
        }
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ShimmerThinkingLabel()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                if trailerKey != nil {
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
                            guard trailerKeyCardId == viewModel.current?.id else { return }
                            withAnimation(.smooth(duration: 0.2)) { presentedTrailer = trailerKey }
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
            // previous title's clip playing.
            presentedTrailer = nil
        }
        guard let item, let foreignId = Int(item.result.foreignId), foreignId > 0 else {
            withAnimation(.smooth(duration: 0.2)) { trailerKey = nil }
            trailerKeyCardId = nil
            return
        }
        let found: String?
        switch item.kind {
        case .movie:
            found = await TrailerProvider.movieTrailerKey(
                radarrTrailerId: nil, tmdbId: foreignId, configStore: ConfigStore.shared
            )
        case .show:
            found = await TrailerProvider.seriesTrailerKey(
                tmdbId: nil, tvdbId: foreignId, configStore: ConfigStore.shared
            )
        }
        // The deck may have moved on while TMDB was answering.
        guard viewModel.current?.id == item.id else { return }
        trailerKeyCardId = found == nil ? nil : item.id
        withAnimation(.smooth(duration: 0.2)) { trailerKey = found }
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
        guard viewModel.current != nil, presentedTrailer == nil, !verdictInFlight,
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
        Task { @MainActor in
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
            SearchAddRequest.post(item.result)
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
                    .controlSize(.small)
                Text("discover.lookingForMore.label", bundle: .module)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
                if viewModel.llmPoolExhausted && llmAvailable
                   && !viewModel.moodText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        Task { await viewModel.requestMoreLLM() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("discover.moreAiSuggestions.button", bundle: .module)
                        }
                        .scaledFont(size: 11, weight: .semibold)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                        .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
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
            // Setup hints and per-source diagnostics explain an EMPTY deck.
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
                if !viewModel.failedSources.isEmpty {
                    Text(failureBadgeText)
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                }
                let counts = viewModel.lastFetchedCounts
                if !counts.isEmpty {
                    Text(verbatim: countsLabel(counts))
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func countsLabel(_ counts: [DiscoverViewModel.Source: Int]) -> String {
        var parts: [String] = []
        if let n = counts[.tmdb] { parts.append("TMDB: \(n)") }
        if let n = counts[.library] { parts.append("Library: \(n)") }
        if let n = counts[.llm] { parts.append("AI: \(n)") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var failureBadgeText: String {
        let names = viewModel.failedSources.map { src -> String in
            switch src {
            case .tmdb:    return "TMDB"
            case .library: return "Library"
            case .llm:     return "AI"
            }
        }.sorted().joined(separator: ", ")
        return "\(names) unavailable"
    }
}

// MARK: - Layout constants

private enum Layout {
    static let buttonDiameter: CGFloat = 62
    static let buttonBottomPadding: CGFloat = 24
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

/// A round, icon-only glass button that stays legible over arbitrary poster
/// art. Same readable-glass recipe as `selectionModeBar` (ultra-thin material
/// + white sheen + bright rim + shadow), shaped as a circle. Used for the
/// swipe verdict buttons and the floating back button.
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
                .overlay(Circle().strokeBorder(Color.white.opacity(0.42), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
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

    private var glassCircle: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                Circle().fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
    }
}
