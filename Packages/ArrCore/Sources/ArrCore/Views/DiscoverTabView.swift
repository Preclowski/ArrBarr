import SwiftUI

public struct DiscoverTabView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let radarrAvailable: Bool
    let onAddToRadarr: (SearchResult) -> Void
    let onAddToSonarr: (SearchResult) -> Void
    let onOpenDetail: (DiscoverItem, QueueItem.Source, Int) -> Void

    @State private var showMatched: Bool = false
    @State private var dragOffset: CGSize = .zero
    @State private var isCardHovered: Bool = false
    @State private var isDragging: Bool = false

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                radarrAvailable: Bool,
                onAddToRadarr: @escaping (SearchResult) -> Void,
                onAddToSonarr: @escaping (SearchResult) -> Void,
                onOpenDetail: @escaping (DiscoverItem, QueueItem.Source, Int) -> Void) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.radarrAvailable = radarrAvailable
        self.onAddToRadarr = onAddToRadarr
        self.onAddToSonarr = onAddToSonarr
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        ZStack {
            switch viewModel.stage {
            case .picker:
                DiscoverPickerView(
                    viewModel: viewModel,
                    llmAvailable: llmAvailable,
                    onSubmit: {
                        withAnimation(.smooth(duration: 0.22)) { viewModel.stage = .tinder }
                        Task { await viewModel.reshuffle() }
                    }
                )
            case .tinder:
                tinderMode
            }
        }
        // No `.task(id:)` for filter changes here anymore — explicit
        // submit via picker is the only reshuffle trigger.
    }

    // MARK: - Tinder mode

    private var tinderMode: some View {
        VStack(spacing: 0) {
            tinderTopBar
            if showMatched {
                DiscoverMatchedListView(
                    items: viewModel.matched,
                    onAct: dispatch,
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
        var parts: [String] = []
        if viewModel.filter.decade.range != nil {
            parts.append(viewModel.filter.decade.rawValue)
        }
        if !viewModel.filter.genres.isEmpty {
            parts.append(viewModel.filter.genres.map(\.displayName).sorted().joined(separator: ", "))
        }
        if viewModel.filter.rating != .any {
            parts.append(viewModel.filter.rating.rawValue.capitalized)
        }
        if viewModel.filter.runtime != .any {
            parts.append(viewModel.filter.runtime.rawValue.capitalized)
        }
        if !viewModel.filter.personIds.isEmpty {
            let count = viewModel.filter.personIds.count
            parts.append("\(count) person\(count == 1 ? "" : "s")")
        }
        if !viewModel.moodText.trimmingCharacters(in: .whitespaces).isEmpty {
            let mood = viewModel.moodText.trimmingCharacters(in: .whitespaces)
            let truncated = mood.count > 24 ? String(mood.prefix(24)) + "\u{2026}" : mood
            parts.append("\u{201C}\(truncated)\u{201D}")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var tinderTopBar: some View {
        HStack(spacing: 6) {
            FloatingBackButton(action: {
                if showMatched {
                    withAnimation(.smooth(duration: 0.22)) { showMatched = false }
                } else {
                    withAnimation(.smooth(duration: 0.22)) { viewModel.stage = .picker }
                }
            })
            if showMatched {
                Text("Your picks", bundle: .module)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else if !activeFilterSummary.isEmpty {
                filterSummaryChip
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
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
            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    clearAllFilters()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(Text("Clear filters", bundle: .module))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
    }

    private func clearAllFilters() {
        viewModel.filter.decade = .any
        viewModel.filter.genres = []
        viewModel.filter.rating = .any
        viewModel.filter.runtime = .any
        viewModel.filter.personIds = []
        viewModel.moodText = ""
        viewModel.userChangedFilter()
        Task { await viewModel.reshuffle() }
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
            // bottom of tinderMode as `ctaIsland` (thinMaterial strip,
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
        withAnimation(.easeOut(duration: 0.28)) {
            dragOffset = target
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            await viewModel.swipe(right: right)
            dragOffset = .zero
            isDragging = false
        }
    }

    private var visibleStack: [DiscoverItem] {
        let curr = viewModel.current.map { [$0] } ?? []
        let peek = Array(viewModel.queue.prefix(2))
        return curr + peek
    }

    private var cardActionRow: some View {
        HStack(spacing: 8) {
            Button { Task { await viewModel.swipe(right: false) } } label: {
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

            Button { Task { await viewModel.swipe(right: true) } } label: {
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
                } label: {
                    Text("Show your picks", bundle: .module)
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            Button {
                withAnimation(.smooth(duration: 0.22)) { viewModel.stage = .picker }
            } label: {
                Text("Back to mood", bundle: .module)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
            if !viewModel.failedSources.isEmpty {
                Text(failureBadgeText)
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
