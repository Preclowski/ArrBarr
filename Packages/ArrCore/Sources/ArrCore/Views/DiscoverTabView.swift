import SwiftUI

public struct DiscoverTabView: View {
    var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let radarrAvailable: Bool
    let onClose: () -> Void
    let onRequestMore: (_ mood: String, _ kept: [DiscoverItem], _ skipped: [DiscoverItem]) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                radarrAvailable: Bool,
                onClose: @escaping () -> Void,
                onRequestMore: @escaping (_ mood: String, _ kept: [DiscoverItem], _ skipped: [DiscoverItem]) -> Void = { _, _, _ in }) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.radarrAvailable = radarrAvailable
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
            .overlay(alignment: .top) { floatingTopChrome }
            .overlay(alignment: .bottom) {
                if viewModel.current != nil {
                    actionButtons
                }
            }
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
            if !activeFilterSummary.isEmpty {
                filterSummaryChip
                    .frame(maxWidth: 220)
            }
            HStack {
                GlassCircleButton(
                    systemName: "chevron.left",
                    tint: .primary,
                    diameter: 34,
                    accessibilityKey: "settings.back.button",
                    action: onClose
                )
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    /// The two round, icon-only verdict buttons. ⏩ = skip to the next card
    /// (neutral), + = add to collection (accent). Each lifts as the drag heads
    /// its way; colours mirror the swipe tint (right = accent, left = neutral).
    private var actionButtons: some View {
        HStack(spacing: 30) {
            GlassCircleButton(
                systemName: "forward.fill",
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

    // MARK: - Top-chrome pieces

    private var activeFilterSummary: String {
        let mood = viewModel.moodText.trimmingCharacters(in: .whitespaces)
        guard !mood.isEmpty else { return "" }
        return mood.count > 40 ? String(mood.prefix(40)) + "\u{2026}" : mood
    }

    private var filterSummaryChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(activeFilterSummary)
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassPill()
    }

    // MARK: - Empty stack

    @ViewBuilder
    private var emptyStackState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "rectangle.stack.fill")
                .scaledFont(size: 22, weight: .light)
                .foregroundStyle(.tertiary)
            Text("discover.noMoreCards.button", bundle: .module)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
            Button {
                onClose()
            } label: {
                Text("discover.backToMood.button", bundle: .module)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if viewModel.hasSessionEngagement {
                Button {
                    onRequestMore(viewModel.moodText,
                                  viewModel.sessionMatched,
                                  viewModel.sessionSkipped)
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
                .padding(.top, 6)
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
