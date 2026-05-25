import SwiftUI

public struct DiscoverTabView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let radarrAvailable: Bool
    let onAddToRadarr: (SearchResult) -> Void
    let onOpenDetail: (DiscoverItem, Int) -> Void

    @State private var mode: Mode = .picker
    @State private var showMatched: Bool = false

    private enum Mode { case picker, tinder }

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                radarrAvailable: Bool,
                onAddToRadarr: @escaping (SearchResult) -> Void,
                onOpenDetail: @escaping (DiscoverItem, Int) -> Void) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.radarrAvailable = radarrAvailable
        self.onAddToRadarr = onAddToRadarr
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        ZStack {
            switch mode {
            case .picker:
                DiscoverPickerView(
                    viewModel: viewModel,
                    llmAvailable: llmAvailable,
                    onSubmit: {
                        withAnimation(.smooth(duration: 0.22)) { mode = .tinder }
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
            Divider()
            if showMatched {
                DiscoverMatchedListView(
                    items: viewModel.matched,
                    onAct: dispatch,
                    onRemove: { item in viewModel.removeMatch(id: item.dedupKey) },
                    onKeepPlaying: { withAnimation(.smooth) { showMatched = false } }
                )
            } else {
                swipingContent
            }
        }
    }

    /// Top bar inside tinder mode — Back-to-mood + Matches pill.
    /// No structured filter chips here per UX direction; mood adjustments
    /// happen by going back to the picker.
    private var tinderTopBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.22)) { mode = .picker }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .scaledFont(size: 11, weight: .semibold)
                    Text("Mood", bundle: .module)
                        .scaledFont(size: 11, weight: .semibold)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(Text("Back to mood picker", bundle: .module))

            Spacer()

            if viewModel.matched.count > 0 {
                Button {
                    withAnimation(.smooth) { showMatched.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.stack.fill")
                            .scaledFont(size: 11, weight: .semibold)
                        Text(verbatim: "\(viewModel.matched.count)")
                            .scaledFont(size: 11, weight: .semibold)
                    }
                    .foregroundStyle(showMatched ? .white : Color.accentColor)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(showMatched
                                               ? Color.accentColor
                                               : Color.accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help(Text("Your picks", bundle: .module))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func dispatch(_ item: DiscoverItem) {
        switch item.action {
        case .addToRadarr: onAddToRadarr(item.result)
        case .openDetail(let arrId): onOpenDetail(item, arrId)
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
            VStack(spacing: 14) {
                cardStack
                cardActionRow
            }
            .padding(.horizontal, 28)         // visible side margins
            .padding(.top, 14)
            .padding(.bottom, 14)
        } else {
            emptyStackState
        }
    }

    /// 3-card stack: top + 2 behind. Cap card height to 0.92 of the
    /// available vertical space so the peeking cards underneath actually
    /// peek (stack effect requires breathing room).
    private var cardStack: some View {
        let stack = visibleStack.enumerated().map { ($0, $1) }
        return GeometryReader { proxy in
            let cardWidth  = proxy.size.width
            let cardHeight = proxy.size.height * 0.92  // leave ~8% so 3rd card's offset stays in view
            ZStack {
                ForEach(stack.reversed(), id: \.1.id) { (idx, item) in
                    DiscoverCardView(item: item)
                        .frame(width: cardWidth, height: cardHeight)
                        .scaleEffect(1.0 - CGFloat(idx) * 0.06, anchor: .top)
                        .offset(y: CGFloat(idx) * 16)
                        .opacity(idx == 0 ? 1.0 : 1.0 - Double(idx) * 0.20)
                        .allowsHitTesting(idx == 0)
                        .zIndex(Double(stack.count - idx))
                        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                                   value: viewModel.current?.dedupKey)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var visibleStack: [DiscoverItem] {
        let curr = viewModel.current.map { [$0] } ?? []
        let peek = Array(viewModel.queue.prefix(2))
        return curr + peek
    }

    private var cardActionRow: some View {
        HStack(spacing: 10) {
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
        }
    }

    private var rightActionIcon: String {
        guard let item = viewModel.current else { return "plus" }
        switch item.action {
        case .addToRadarr: return "plus"
        case .openDetail:  return "play.fill"
        }
    }
    private var rightActionLabel: LocalizedStringKey {
        guard let item = viewModel.current else { return "Add to Radarr" }
        switch item.action {
        case .addToRadarr: return "Add to Radarr"
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
                withAnimation(.smooth(duration: 0.22)) { mode = .picker }
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
