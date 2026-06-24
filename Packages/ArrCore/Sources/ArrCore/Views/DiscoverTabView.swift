import SwiftUI

public struct DiscoverTabView: View {
    var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let radarrAvailable: Bool
    let onAddToRadarr: (SearchResult) -> Void
    let onAddToSonarr: (SearchResult) -> Void
    let onOpenDetail: (DiscoverItem, QueueItem.Source, Int) -> Void
    let onClose: () -> Void
    let onRequestMore: (_ mood: String, _ kept: [DiscoverItem], _ skipped: [DiscoverItem], _ disliked: [DiscoverItem]) -> Void

    @State private var showMatched: Bool = false
    @State private var dragOffset: CGSize = .zero
    @State private var isCardHovered: Bool = false
    @State private var isDragging: Bool = false

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                radarrAvailable: Bool,
                onAddToRadarr: @escaping (SearchResult) -> Void,
                onAddToSonarr: @escaping (SearchResult) -> Void,
                onOpenDetail: @escaping (DiscoverItem, QueueItem.Source, Int) -> Void,
                onClose: @escaping () -> Void,
                onRequestMore: @escaping (_ mood: String, _ kept: [DiscoverItem], _ skipped: [DiscoverItem], _ disliked: [DiscoverItem]) -> Void = { _, _, _, _ in }) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.radarrAvailable = radarrAvailable
        self.onAddToRadarr = onAddToRadarr
        self.onAddToSonarr = onAddToSonarr
        self.onOpenDetail = onOpenDetail
        self.onClose = onClose
        self.onRequestMore = onRequestMore
    }

    public var body: some View {
        quizMode
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrShowDiscoverPicks)) { _ in
                withAnimation(.smooth(duration: 0.22)) {
                    showMatched = true
                }
                viewModel.acknowledgeUnseenPicks()
            }
    }

    // MARK: - Quiz mode

    private var quizMode: some View {
        VStack(spacing: 0) {
            quizTopBar
            if showMatched {
                DiscoverMatchedListView(
                    items: viewModel.matched,
                    onRemove: { item in viewModel.removeMatch(id: item.dedupKey) }
                )
            } else {
                swipingContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if viewModel.current != nil {
                    ctaIsland
                }
            }
        }
    }

    /// Sticky bottom CTA "island" — same shape as DetailView's
    /// downloadCTAStrip: thinMaterial panel spanning edge-to-edge with
    /// a hairline divider on top. Keeps Skip / Watch / List visually
    /// grouped on a single surface instead of floating in dead space.
    private var ctaIsland: some View {
        cardActionRow
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                Rectangle()
                    .fill(.thinMaterial)
                    .overlay(alignment: .top) {
                        Divider().opacity(0.4)
                    }
            )
    }

    private var activeFilterSummary: String {
        let mood = viewModel.moodText.trimmingCharacters(in: .whitespaces)
        guard !mood.isEmpty else { return "" }
        return mood.count > 40 ? String(mood.prefix(40)) + "\u{2026}" : mood
    }

    private var quizTopBar: some View {
        // Three-zone header: back-button left, centered title/filter,
        // picks-count pill right. Centring via ZStack so the centre
        // element doesn't shift when the side widths change.
        ZStack {
            if showMatched {
                Text("discover.yourPicks.button", bundle: .module)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else if !activeFilterSummary.isEmpty {
                filterSummaryChip
            }
            HStack(spacing: 6) {
                FloatingBackButton(action: {
                    if showMatched {
                        withAnimation(.smooth(duration: 0.22)) { showMatched = false }
                    } else {
                        onClose()
                    }
                })
                Spacer()
                if !showMatched && !viewModel.matched.isEmpty {
                    picksCountPill
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// Pill showing the shortlist count: `★ N`. Only rendered when at
    /// least one pick exists — there's no useful zero-state for it.
    /// Tinted accent when there are unseen picks so the user notices
    /// without an attention-grabbing pulse animation.
    private var picksCountPill: some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) {
                showMatched = true
            }
            viewModel.acknowledgeUnseenPicks()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .scaledFont(size: 10, weight: .semibold)
                Text(verbatim: "\(viewModel.matched.count)")
                    .scaledFont(size: 12, weight: .semibold)
                    .monospacedDigit()
            }
            .foregroundStyle(viewModel.hasUnseenPicks ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // Without this the Button only hit-tests the star glyph + the
            // digits — the transparent padding / inter-element gap fell
            // through. Make the whole padded pill the tap target.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassPill()
        .help(Text("discover.yourPicks.button", bundle: .module))
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

    // MARK: - Swiping content (cards + CTAs)

    @ViewBuilder
    private var swipingContent: some View {
        if viewModel.isLoading && viewModel.current == nil {
            VStack {
                Spacer()
                ShimmerThinkingLabel()
                Spacer()
            }
        } else if viewModel.current != nil {
            cardStack
                .padding(.horizontal, 28)
                .padding(.top, 6)
                .padding(.bottom, 28)
            // cardActionRow no longer sits here — it's pinned at the
            // bottom of quizMode as `ctaIsland` (thinMaterial strip,
            // same pattern as DetailView's downloadCTAStrip).
        } else {
            emptyStackState
        }
    }

    private var cardStack: some View {
        let stack = visibleStack.enumerated().map { ($0, $1) }
        return GeometryReader { proxy in
            // Reserve ~12% vertical for the peek stack at the bottom.
            let availableH = proxy.size.height * 0.88
            // True 2:3 poster aspect (restored from 1.4 → 1.5).
            let h = min(availableH, proxy.size.width * 1.5)
            let w = h / 1.5
            ZStack {
                ForEach(stack.reversed(), id: \.1.id) { (idx, item) in
                    let isTop = (idx == 0)
                    let tmdbId = Int(item.result.foreignId) ?? item.result.id
                    DiscoverCardStackItem(
                        item: item,
                        idx: idx,
                        stackCount: stack.count,
                        cardWidth: w,
                        cardHeight: h,
                        dragOffset: dragOffset,
                        credits: isTop ? viewModel.creditsCache[tmdbId] : nil,
                        tmdbId: tmdbId,
                        stackRotation: stackRotation(for: item, idx: idx),
                        animationKey: viewModel.current?.dedupKey,
                        isHovered: isTop ? $isCardHovered : .constant(false),
                        hoverState: isCardHovered,
                        gesture: isTop ? dragGesture : nil,
                        onHoverForCredits: { viewModel.fetchCreditsIfNeeded(for: $0) }
                    )
                }
            }
            // Center the stack vertically so empty space splits above + below.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func stackRotation(for item: DiscoverItem, idx: Int) -> Angle {
        // Top card sits flat. Peek cards tilt a few degrees in alternating
        // directions, deterministic per item so the layout doesn't shuffle.
        guard idx > 0 else { return .zero }
        // FNV-1a-ish hash → -1..+1
        var h: UInt32 = 2166136261
        for byte in item.dedupKey.utf8 { h ^= UInt32(byte); h = h &* 16777619 }
        let normalized = Double(h % 200) / 100.0 - 1.0  // -1..+1
        let degrees = normalized * 3.5  // ±3.5° max
        return .degrees(degrees)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // Suppress hover/drawer the moment a drag starts so the
                // card actually moves under the cursor instead of being
                // gated off by isCardHovered.
                if !isDragging { isDragging = true }
                if isCardHovered { isCardHovered = false }
                dragOffset = value.translation
            }
            .onEnded { value in
                let threshold: CGFloat = 90
                if value.translation.width > threshold {
                    completeSwipe(right: true, fromTranslation: value.translation)
                } else if value.translation.width < -threshold {
                    // Left drag = thumbs-down. Same semantic as the
                    // left button — tagged for "fewer like this", not
                    // a silent skip.
                    handleMarkDisliked()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        dragOffset = .zero
                    }
                }
                isDragging = false
            }
    }

    private func completeSwipe(right: Bool, fromTranslation t: CGSize) {
        let flyDistance: CGFloat = 1000
        let target = CGSize(width: right ? flyDistance : -flyDistance, height: t.height)
        withAnimation(.easeOut(duration: 0.55)) {
            dragOffset = target
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            await viewModel.swipe(right: right)
            dragOffset = .zero
            isDragging = false
        }
    }

    private func handleMarkDisliked() {
        // Same fly-off animation as a left-swipe so the gesture+button
        // feedback are consistent.
        let flyDistance: CGFloat = 1000
        let target = CGSize(width: -flyDistance, height: 0)
        withAnimation(.easeOut(duration: 0.45)) {
            dragOffset = target
        }
        viewModel.markDisliked()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                dragOffset = .zero
            }
        }
    }

    private var visibleStack: [DiscoverItem] {
        let curr = viewModel.current.map { [$0] } ?? []
        let peek = Array(viewModel.queue.prefix(2))
        return curr + peek
    }

    private var cardActionRow: some View {
        // Two-button verdict: thumbs-down (red, taggs "fewer like this")
        // and thumbs-up (accent, drops the card into the shortlist).
        // No immediate add to library — the user reviews the shortlist
        // (`DiscoverMatchedListView`) and adds from there.
        HStack(spacing: 8) {
            Button {
                handleMarkDisliked()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hand.thumbsdown.fill")
                        .scaledFont(size: 13, weight: .semibold)
                    Text("discover.no.button", bundle: .module)
                        .scaledFont(size: 12, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .modifier(GlassProminentButtonStyle())
            .tint(.red)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help(Text("discover.fewerLikeThis.button", bundle: .module))

            Button {
                completeSwipe(right: true, fromTranslation: .zero)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hand.thumbsup.fill")
                        .scaledFont(size: 13, weight: .semibold)
                    Text("discover.yes.button", bundle: .module)
                        .scaledFont(size: 12, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .modifier(GlassProminentButtonStyle())
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help(Text("discover.saveToPicks.button", bundle: .module))
        }
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
            if viewModel.matched.count > 0 {
                Button {
                    withAnimation(.smooth) { showMatched = true }
                    viewModel.acknowledgeUnseenPicks()
                } label: {
                    Text("discover.showYourPicks.button", bundle: .module)
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
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
                                  viewModel.sessionSkipped,
                                  viewModel.sessionDisliked)
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

/// A single card in the Quiz swipe stack: the poster card plus its full
/// transform chain (scale / offset / rotation / opacity / gesture).
/// Extracted from `DiscoverTabView.cardStack`'s `ForEach` closure so that
/// closure stays trivial to type-check — the long modifier chain lived
/// inline and pushed the getter over the 100ms warn threshold.
private struct DiscoverCardStackItem<G: Gesture>: View {
    let item: DiscoverItem
    let idx: Int
    let stackCount: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let dragOffset: CGSize
    let credits: TMDBCredits?
    let tmdbId: Int
    let stackRotation: Angle
    let animationKey: String?
    @Binding var isHovered: Bool
    let hoverState: Bool
    let gesture: G?
    let onHoverForCredits: (Int) -> Void

    private var isTop: Bool { idx == 0 }

    var body: some View {
        DiscoverCardView(item: item,
                         isHovered: $isHovered,
                         dragOffset: isTop ? dragOffset : .zero,
                         credits: credits)
            .frame(width: cardWidth, height: cardHeight)
            .scaleEffect(1.0 - CGFloat(idx) * 0.04, anchor: .top)
            .offset(x: isTop ? dragOffset.width : 0,
                    y: CGFloat(idx) * 22 + (isTop ? dragOffset.height * 0.3 : 0))
            .rotationEffect(
                isTop
                    ? .degrees(Double(dragOffset.width / 18))
                    : stackRotation,
                anchor: isTop ? .bottom : .center
            )
            .opacity(idx == 0 ? 1.0 : 1.0 - Double(idx) * 0.15)
            .allowsHitTesting(isTop)
            .zIndex(Double(stackCount - idx))
            .gesture(gesture)
            .animation(.spring(response: 0.32, dampingFraction: 0.85),
                       value: animationKey)
            .onChange(of: hoverState) { _, hovering in
                if hovering && isTop && tmdbId > 0 {
                    onHoverForCredits(tmdbId)
                }
            }
    }
}
