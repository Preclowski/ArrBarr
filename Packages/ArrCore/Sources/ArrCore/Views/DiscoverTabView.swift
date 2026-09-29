import SwiftUI

struct DiscoverTabView: View {
    var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let radarrAvailable: Bool
    /// True while the agent works on a turn. The top-up round is a chat turn, so this beats
    /// any fixed timer as the answer to "still looking?".
    var moreInFlight: Bool = false
    /// An overlay covers the parked deck. Parking disables clicks, but keyboard focus is its
    /// own channel — without this the arrow keys swipe cards underneath.
    var isObscured: Bool = false
    let onClose: () -> Void
    let onCancelLoading: () -> Void
    let onRequestMore: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false
    @State private var requestingMore: Bool = false
    /// `sessionTotal` at the last background top-up; it only grows when items land, so this
    /// throttles to one request per deck-tail and re-arms once the deck grew.
    @State private var prefetchedAtTotal: Int?
    /// Escape hatch for a round that never resolves; held so a new request cancels the old timer.
    @State private var moreTimeout: Task<Void, Never>?
    /// Each dry tail gets exactly one silent retry; cleared when cards land.
    @State private var emptyRoundRetried = false
    @State private var trailer: TrailerReel?
    /// While this lags the top card the button stays but is inert — it would play the
    /// previous card's clip.
    @State private var trailerCardId: String?
    @ObservedObject private var trailerSession = TrailerSession.shared
    /// Arrow keys only reach `onKeyPress` while something is focused.
    @FocusState private var deckFocused: Bool
    /// The skip animation runs 550 ms before the drop; a second verdict inside it (a held
    /// arrow key) would advance the deck twice while one card left.
    @State private var verdictInFlight = false
    /// Pinned for the whole verdict: `viewModel` is `@Observable` and `dragOffset` is `@State`,
    /// so a live `queue.first` can point one card too far for a frame and flash it.
    @State private var pinnedIncomingBackdrop: URL?

    init(viewModel: DiscoverViewModel,
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

    var body: some View {
        ZStack {
            if let phase = viewModel.loadPhase {
                QuizLoadingView(phase: phase, startedAt: viewModel.loadStartedAt,
                                posters: viewModel.loadingPosters, onCancel: onCancelLoading)
                    .transition(.blurReplace)
            } else {
                // The first card comes into focus out of the blurred wait, like a print developing.
                swipeSurface
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.9), value: viewModel.loadPhase == nil)
    }

    // MARK: - Immersive swipe surface

    /// Split into three stages because as one chain it exceeds the type-checker's patience.
    private var swipeSurface: some View {
        deckWithKeyboard
            // Top up from the second-to-last card: the refill is a slow chat round-trip, so waiting
            // for the empty state means seconds of spinner.
            .onChange(of: viewModel.queue.count) { _, remaining in
                guard remaining <= 1 else { return }
                prefetchMoreIfNeeded()
            }
            // Items landed — the round is over, whatever the timer thinks.
            .onChange(of: viewModel.sessionTotal) { _, _ in
                finishRequestingMore()
                emptyRoundRetried = false
            }
            // The agent stopped: picks landed (above) or it answered without the tool — nothing to wait for.
            .onChange(of: moreInFlight) { wasInFlight, nowInFlight in
                guard wasInFlight, !nowInFlight else { return }
                finishRequestingMore()
                // Take a top-up skipped while the agent was mid-turn. Can't loop: `prefetchedAtTotal`
                // only re-arms once items land.
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

    private var decoratedDeck: some View {
        swipeBackground
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(blurredBackdrop)
            .overlay(alignment: .top) {
                // The deck has no top gradient of its own, so the chevron and mood chip need a darken
                // over bright artwork.
                if viewModel.current != nil { topLegibilityScrim }
            }
            .overlay(alignment: .top) { floatingTopChrome }
            .overlay(alignment: .bottom) {
                if viewModel.current != nil {
                    actionButtons
                }
            }
            // The permanent "no" hides behind a deliberate gesture; the ✕ is only a cooldown.
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

    /// Same fly-off as a skip; only the memory of it differs.
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

    /// ← mirrors the ✕ button, → opens the add card like a right swipe.
    private var deckWithKeyboard: some View {
        decoratedDeck
            .focusable(viewModel.current != nil && !isObscured)
            .focusEffectDisabled()
            .focused($deckFocused)
            .onKeyPress(.leftArrow) { keyVerdict(skip: true) }
            .onKeyPress(.rightArrow) { keyVerdict(skip: false) }
            .onAppear { deckFocused = true }
            .onChange(of: isObscured) { _, obscured in deckFocused = !obscured }
            // Refocus when the deck is live again (after an add or a dismissed trailer), so keys work
            // without clicking the poster first.
            .onChange(of: viewModel.current?.id) { _, _ in deckFocused = true }
            .onChange(of: trailerSession.key) { _, presented in
                if presented == nil { deckFocused = true }
            }
    }

    /// Reuses `requestingMore` so an empty-state button shown before the round lands is already
    /// spinning and disabled — no second identical request.
    private func prefetchMoreIfNeeded() {
        // Without an LLM the request goes nowhere; without engagement it has no signal ("more like what?").
        guard llmAvailable,
              viewModel.current != nil,
              viewModel.hasSessionEngagement,
              !isLookingForMore,
              prefetchedAtTotal != viewModel.sessionTotal else { return }
        // The host drops requests while the agent is mid-turn; `onChange(of: moreInFlight)` retries.
        guard !moreInFlight else { return }
        prefetchedAtTotal = viewModel.sessionTotal
        requestMore()
    }

    /// A dry round (only already-shown titles, or prose with no tool call) is not an exhausted
    /// deck, so retry automatically once per dry tail before calling it done.
    private func retryEmptyRoundIfNeeded() {
        guard llmAvailable,
              viewModel.current == nil,
              viewModel.queue.isEmpty,
              viewModel.hasSessionEngagement,
              !emptyRoundRetried else { return }
        emptyRoundRetried = true
        requestMore()
    }

    private var isLookingForMore: Bool { requestingMore || moreInFlight }

    /// The in-flight state ends when the work ends (`moreInFlight` quiet or items landing), not
    /// on a stopwatch; the timeout is only a stuck-state escape.
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

    private func finishRequestingMore() {
        moreTimeout?.cancel()
        moreTimeout = nil
        requestingMore = false
    }

    /// Transparent by ~90 pt so it never touches the card's bottom metadata.
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

    /// Blurred artwork filling the letterboxing a phone leaves around a 2:3 poster.
    private var blurredBackdrop: some View {
        ZStack {
            Color.black
            if let url = viewModel.current?.result.posterURL {
                // No `.id(url)`: remounting resets `RemotePoster`'s image to nil and flashes a placeholder
                // frame; reused, it keeps the old image until the new one decodes.
                backdropLayer(url: url)
            }
            if let next = pinnedIncomingBackdrop {
                // No `.id`, same as above.
                backdropLayer(url: next)
                    .opacity(incomingBackdropOpacity)
            }
        }
        .ignoresSafeArea()
    }

    /// Driven by `dragOffset`, not a transition — those only start after the deck advances,
    /// 550 ms late. 200 pt (vs the card's 90 pt tint) so a hesitant drag only hints.
    private var incomingBackdropOpacity: Double {
        guard isDragging || verdictInFlight else { return 0 }
        let travelled = -dragOffset.width
        guard travelled > 0 else { return 0 }
        return Double(min(1, travelled / 200))
    }

    /// Never mid-verdict, which is the whole point of pinning.
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
            // Scale first, then blur: blurring at frame size leaves a soft transparent rim.
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
                FloatingBackButton(action: onClose)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var actionButtons: some View {
        // Helpers sit on the edges so their appearance never shoves the verdict pair sideways.
        ZStack {
            centeredVerdictButtons
            HStack {
                if viewModel.canUndoSkip {
                    GlassCircleButton(
                        systemName: "arrow.uturn.backward",
                        tint: .secondary,
                        diameter: QuizLayout.buttonDiameter * 0.72,
                        accessibilityKey: "discover.undo.button",
                        action: handleUndo
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                Spacer()
                if trailer != nil {
                    GlassCircleButton(
                        assetName: "brand-youtube",
                        diameter: QuizLayout.buttonDiameter * 0.72,
                        accessibilityKey: "discover.trailer.button",
                        action: {
                            // Ignore taps aimed at a clip not yet resolved for this card.
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
        .padding(.bottom, QuizLayout.buttonBottomPadding)
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

    /// `foreignId` is a TMDB movie id on movie cards but a TVDB series id on show cards.
    private func resolveTrailer(for item: DiscoverItem?) async {
        // Keep the button while the next card resolves, or it blinks between cards and resizes the row.
        withAnimation(.smooth(duration: 0.2)) {
            // Dismiss only OUR clip: a session restored across a popover reopen belongs to whoever started it.
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
                        bottomInset: QuizLayout.cardBottomInset,
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
        // One hidden peek card is enough; it scales up as the top flies off.
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
                    // Does not advance — a cancelled add returns to this card.
                    handleAdd()
                } else if value.translation.width < -threshold {
                    handleSkip()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        dragOffset = .zero
                    }
                    isDragging = false
                }
            }
    }

    /// Records the pick but does not advance: add or cancel both return to this card.
    private func handleAdd() {
        guard let item = viewModel.current else { return }
        isDragging = false
        dragOffset = .zero
        viewModel.markPicked()
        openCard(for: item)
    }

    /// Ignored, not queued, mid-fly-off or with the trailer up, so a held arrow can't burn the deck.
    private func keyVerdict(skip: Bool) -> KeyPress.Result {
        guard viewModel.current != nil, trailerSession.key == nil, !verdictInFlight,
              !isObscured else { return .ignored }
        if skip { handleSkip() } else { handleAdd() }
        return .handled
    }

    /// No fly-off: the correction should feel like stepping back, not a fourth swipe direction.
    private func handleUndo() {
        guard !verdictInFlight else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            viewModel.undoSkip()
        }
        dragOffset = .zero
        isDragging = false
    }

    /// Fly off first, then drop — the peek card scales up instead of the next one sliding in.
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

    /// Owned items open DetailView, fresh ones SearchAddPanel; PopoverContentView owns the swap.
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

    /// Two states, never mixed: while a round is in flight the surface only says it's looking.
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
                WaitFactTicker(facts: WaitFacts.watching())
                    .padding(.horizontal, 24)
            } else {
                Image(systemName: "rectangle.stack.fill")
                    .scaledFont(size: 26, weight: .light)
                    .foregroundStyle(.tertiary)
                Text("discover.noMoreCards.button", bundle: .module)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                Text("discover.thatsEverything.label", bundle: .module)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                // A mis-swipe hurts most at the end of the deck, so offer the rewind here too.
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
                // The agent fetches the round, so without an LLM the tap goes nowhere.
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
            Button {
                onClose()
            } label: {
                Text("discover.backToMood.button", bundle: .module)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            // Setup hints explain an empty deck; mid-round they'd contradict the "looking" state.
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

/// The quiz's button geometry, shared with its wait screen so Cancel sits where the card's buttons will.
enum QuizLayout {
    static let buttonDiameter: CGFloat = 62
    /// 24 was tuned for the popover; on a phone it puts the buttons in the home-indicator strip,
    /// which eats touches.
    #if os(iOS)
    static let buttonBottomPadding: CGFloat = 44
    #else
    static let buttonBottomPadding: CGFloat = 24
    #endif
    static let cardBottomInset: CGFloat = buttonDiameter + buttonBottomPadding + 20
}

// MARK: - Card stack item

/// Extracted from `cardStack`'s `ForEach` so that closure stays cheap to type-check.
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

struct GlassCircleButton: View {
    /// Ignored when `assetName` is set.
    var systemName: String = ""
    /// Drawn in its own colours — a monochrome YouTube glyph is not the mark.
    var assetName: String?
    var tint: Color = .primary
    var diameter: CGFloat = QuizLayout.buttonDiameter
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

    /// Clear glass, no tint: the card's own bottom scrim is the dimming layer clear glass asks for.
    private var glassCircle: some View {
        Circle()
            .fill(.clear)
            .glassEffect(.clear.interactive(), in: .circle)
    }
}
