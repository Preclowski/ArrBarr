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
                    onRemove: { item in viewModel.removeMatch(id: item.dedupKey) },
                    onKeepPlaying: { withAnimation(.smooth) { showMatched = false } }
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

    private var tinderTopBar: some View {
        HStack(spacing: 6) {
            FloatingBackButton(action: {
                withAnimation(.smooth(duration: 0.22)) {
                    viewModel.stage = .picker
                }
            })
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
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
                ProgressView().controlSize(.small)
                Spacer()
            }
        } else if viewModel.current != nil {
            cardStack
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 14)
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
                    DiscoverCardView(item: item)
                        .frame(width: w, height: h)
                        .scaleEffect(1.0 - CGFloat(idx) * 0.08, anchor: .top)
                        .offset(x: isTop ? dragOffset.width : 0,
                                y: CGFloat(idx) * 18 + (isTop ? dragOffset.height * 0.3 : 0))
                        .rotationEffect(.degrees(isTop ? Double(dragOffset.width / 18) : 0),
                                        anchor: .bottom)
                        .opacity(idx == 0 ? 1.0 : 1.0 - Double(idx) * 0.28)
                        .allowsHitTesting(isTop)
                        .zIndex(Double(stack.count - idx))
                        .gesture(isTop ? dragGesture : nil)
                        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                                   value: viewModel.current?.dedupKey)
                }
            }
            // Center the stack vertically so empty space splits above + below.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
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
                .frame(maxWidth: .infinity)
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

            // Third button: compact list opener with a badge count.
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
        guard let item = viewModel.current else { return "Add to Radarr" }
        switch item.action {
        case .addToRadarr: return "Add to Radarr"
        case .addToSonarr: return "Add to Sonarr"
        case .openDetail:  return "Watch"
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
