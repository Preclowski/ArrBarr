import SwiftUI

public struct DiscoverTabView: View {
    @ObservedObject var viewModel: DiscoverViewModel
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
        HStack(spacing: 6) {
            FloatingBackButton(action: {
                if showMatched {
                    withAnimation(.smooth(duration: 0.22)) { showMatched = false }
                } else {
                    onClose()
                }
            })
            if showMatched {
                Text("Your picks", bundle: .module)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else if !activeFilterSummary.isEmpty {
                filterSummaryChip
                if viewModel.sessionTotal > 0 {
                    progressChip
                }
            }
            Spacer()
            if !showMatched {
                picksToggleButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @State private var picksPulse: Bool = false

    private var picksToggleButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) {
                showMatched = true
            }
            viewModel.acknowledgeUnseenPicks()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: viewModel.matched.isEmpty
                      ? "list.star"
                      : "list.star.rectangle.portrait.fill")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(viewModel.hasUnseenPicks ? 0.15 : 0.06))
                            .scaleEffect(viewModel.hasUnseenPicks && picksPulse ? 1.18 : 1.0)
                            .opacity(viewModel.hasUnseenPicks && picksPulse ? 0.0 : 1.0)
                    )
                    .background(
                        Circle().fill(Color.primary.opacity(0.06))
                    )
                if viewModel.hasUnseenPicks {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(Text("Your picks", bundle: .module))
        .onChange(of: viewModel.hasUnseenPicks) { _, newValue in
            if newValue {
                picksPulse = false
                withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    picksPulse = true
                }
            } else {
                withAnimation(.smooth(duration: 0.2)) {
                    picksPulse = false
                }
            }
        }
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
    }

    private var progressChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "rectangle.stack")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.tertiary)
            Text(verbatim: "\(viewModel.sessionConsumed) / \(viewModel.sessionTotal)")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func dispatch(_ item: DiscoverItem) {
        switch item.action {
        case .addToRadarr:
            onAddToRadarr(item.result)
        case .addToSonarr:
            onAddToSonarr(item.result)
        case .openDetail(let source, let arrId):
            onOpenDetail(item, source, arrId)
        }
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
                    DiscoverCardView(item: item,
                                     isHovered: isTop ? $isCardHovered : .constant(false),
                                     dragOffset: isTop ? dragOffset : .zero,
                                     credits: isTop ? viewModel.creditsCache[tmdbId] : nil)
                        .frame(width: w, height: h)
                        .scaleEffect(1.0 - CGFloat(idx) * 0.04, anchor: .top)
                        .offset(x: isTop ? dragOffset.width : 0,
                                y: CGFloat(idx) * 22 + (isTop ? dragOffset.height * 0.3 : 0))
                        .rotationEffect(
                            isTop
                                ? .degrees(Double(dragOffset.width / 18))
                                : stackRotation(for: item, idx: idx),
                            anchor: isTop ? .bottom : .center
                        )
                        .opacity(idx == 0 ? 1.0 : 1.0 - Double(idx) * 0.15)
                        .allowsHitTesting(isTop)
                        .zIndex(Double(stack.count - idx))
                        .gesture(isTop ? dragGesture : nil)
                        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                                   value: viewModel.current?.dedupKey)
                        .onChange(of: isCardHovered) { _, hovering in
                            if hovering && isTop && tmdbId > 0 {
                                viewModel.fetchCreditsIfNeeded(for: tmdbId)
                            }
                        }
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
                    completeSwipe(right: false, fromTranslation: value.translation)
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
        HStack(spacing: 8) {
            // "Fewer like this" — secondary negative signal. Drops the
            // card like Skip but tags it so the next "More picks" prompt
            // tells the agent to avoid similar items.
            Button {
                handleMarkDisliked()
            } label: {
                Image(systemName: "hand.thumbsdown")
                    .scaledFont(size: 12, weight: .semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help(Text("Fewer like this", bundle: .module))

            Button {
                completeSwipe(right: false, fromTranslation: .zero)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 11, weight: .semibold)
                    Text("Skip", bundle: .module)
                        .scaledFont(size: 12, weight: .semibold)
                }
                .frame(width: 90)
                .padding(.vertical, 7)
            }
            .modifier(GlassProminentButtonStyle())
            .tint(.red)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button {
                completeSwipe(right: true, fromTranslation: .zero)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: rightActionIcon)
                        .scaledFont(size: 11, weight: .semibold)
                    Text(rightActionLabel, bundle: .module)
                        .scaledFont(size: 12, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .modifier(GlassProminentButtonStyle())
            .keyboardShortcut(.rightArrow, modifiers: [])

            // Third button: compact list opener with badge — keep current.
            Button {
                withAnimation(.smooth) { showMatched.toggle() }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "rectangle.stack.fill")
                        .scaledFont(size: 13, weight: .semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 7)
                    if viewModel.matched.count > 0 {
                        Text(verbatim: "\(min(viewModel.matched.count, 99))")
                            .scaledFont(size: 9, weight: .bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 4, y: -4)
                    }
                }
                .frame(minWidth: 32)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help(Text("Your picks", bundle: .module))
        }
    }

    private var rightActionIcon: String {
        guard let item = viewModel.current else { return "plus" }
        switch item.action {
        case .addToRadarr: return "plus"
        case .addToSonarr: return "tv"
        case .openDetail:  return "play.fill"
        }
    }
    private var rightActionLabel: LocalizedStringKey {
        guard let item = viewModel.current else { return "Pick" }
        switch item.action {
        case .addToRadarr, .addToSonarr: return "Pick"
        case .openDetail:                return "Watch"
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
            Text("No more cards", bundle: .module)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
            if viewModel.matched.count > 0 {
                Button {
                    withAnimation(.smooth) { showMatched = true }
                    viewModel.acknowledgeUnseenPicks()
                } label: {
                    Text("Show your picks", bundle: .module)
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            Button {
                onClose()
            } label: {
                Text("Back to mood", bundle: .module)
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
                        Text("More picks like these", bundle: .module)
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
                        Text("More AI suggestions", bundle: .module)
                    }
                    .scaledFont(size: 11, weight: .semibold)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.purple.opacity(0.12)))
                    .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
            }
            if !radarrAvailable {
                Text("Configure Radarr in Settings to save picks to your library — add-actions will open TMDB instead.",
                     bundle: .module)
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
            }
            if !llmAvailable {
                Text("Configure an LLM provider in Settings to get AI-powered picks.",
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
