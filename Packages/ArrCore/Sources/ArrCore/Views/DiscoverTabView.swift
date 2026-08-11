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

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                radarrAvailable: Bool,
                moreInFlight: Bool = false,
                onClose: @escaping () -> Void,
                onRequestMore: @escaping (_ mood: String, _ kept: [DiscoverItem], _ skipped: [DiscoverItem]) -> Void = { _, _, _ in }) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.radarrAvailable = radarrAvailable
        self.moreInFlight = moreInFlight
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
    private var swipeSurface: some View {
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
            }
            .onDisappear { moreTimeout?.cancel() }
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
        .padding(.bottom, Layout.buttonBottomPadding)
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

    /// Left verdict: skip to the next card. Fly the current card off to the
    /// left, THEN drop it and advance — the peek card scales up to fill
    /// instead of the next card sliding in.
    private func handleSkip() {
        let flyDistance: CGFloat = 1000
        withAnimation(.easeOut(duration: 0.55)) {
            dragOffset = CGSize(width: -flyDistance, height: 0)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            viewModel.skip()
            dragOffset = .zero
            isDragging = false
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
    let systemName: String
    let tint: Color
    var diameter: CGFloat = Layout.buttonDiameter
    /// Transient scale added while a drag heads toward this button.
    var extraScale: CGFloat = 0
    let accessibilityKey: LocalizedStringKey
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.40, weight: .bold))
                .foregroundStyle(tint)
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
