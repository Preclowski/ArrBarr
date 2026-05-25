import SwiftUI

public struct DiscoverTabView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let radarrAvailable: Bool
    let onAddToRadarr: (SearchResult) -> Void
    let onOpenDetail: (DiscoverItem, Int) -> Void

    @State private var showMatched: Bool = false
    @FocusState private var moodFocused: Bool

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
        VStack(spacing: 0) {
            filterRow
            Divider()
            if showMatched {
                DiscoverMatchedListView(
                    items: viewModel.matched,
                    onAct: { item in dispatch(item) },
                    onRemove: { item in viewModel.removeMatch(id: item.dedupKey) },
                    onKeepPlaying: { withAnimation(.smooth) { showMatched = false } }
                )
            } else {
                swipingContent
            }
            moodBar
        }
        .task(id: viewModel.userActionTick) {
            await viewModel.reshuffle()
            // Reshuffle clears matched too — close the panel if we were in it.
            if showMatched { showMatched = false }
        }
    }

    /// Filter bar row + the Matches(N) pill on the right when there are picks.
    private var filterRow: some View {
        HStack(spacing: 8) {
            DiscoverFilterBar(
                filter: Binding(get: { viewModel.filter },
                                set: { viewModel.filter = $0 }),
                onUserChange: { viewModel.userChangedFilter() },
                onReshuffle: { Task { await viewModel.reshuffle() } }
            )
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
                .padding(.trailing, 12)
                .help(Text("Your picks", bundle: .module))
            }
        }
    }

    @ViewBuilder
    private var moodBar: some View {
        if llmAvailable {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .scaledFont(size: 14)
                    .foregroundStyle(.purple)
                TextField("",
                          text: Binding(get: { viewModel.moodText },
                                        set: { viewModel.moodText = $0 }),
                          prompt: Text("What are you in the mood for?", bundle: .module),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($moodFocused)
                    .onSubmit { submitMood() }
                    .lineLimit(1...4)
                    .scaledFont(size: 13)
                Button(action: submitMood) {
                    Image(systemName: "arrow.up.circle.fill")
                        .scaledFont(size: 22)
                        .foregroundStyle(
                            viewModel.moodText
                                .trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.secondary
                                : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.moodText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassyFloatingBar()
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    private func submitMood() {
        moodFocused = false
        viewModel.userSubmittedMood()
    }

    private func dispatch(_ item: DiscoverItem) {
        switch item.action {
        case .addToRadarr:
            onAddToRadarr(item.result)
        case .openDetail(let arrId):
            onOpenDetail(item, arrId)
        }
    }

    @ViewBuilder
    private var swipingContent: some View {
        if viewModel.isLoading && viewModel.current == nil {
            VStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
        } else if viewModel.current != nil {
            VStack(spacing: 12) {
                cardStack
                cardActionRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)
        } else {
            emptyStackState
        }
    }

    /// Top card + up to 2 behind it, offset + scaled + dimmed for the
    /// classic tinder peek. Only the top card receives gestures / keystrokes.
    private var cardStack: some View {
        let stack = visibleStack.enumerated().map { ($0, $1) }
        return ZStack {
            ForEach(stack.reversed(), id: \.1.id) { (idx, item) in
                DiscoverCardView(item: item)
                    .scaleEffect(1.0 - CGFloat(idx) * 0.04, anchor: .top)
                    .offset(y: CGFloat(idx) * 10)
                    .opacity(idx == 0 ? 1.0 : 1.0 - Double(idx) * 0.18)
                    .allowsHitTesting(idx == 0)
                    .zIndex(Double(stack.count - idx))
                    .animation(.spring(response: 0.32, dampingFraction: 0.85),
                               value: viewModel.current?.dedupKey)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleStack: [DiscoverItem] {
        let curr = viewModel.current.map { [$0] } ?? []
        let peek = Array(viewModel.queue.prefix(2))
        return curr + peek
    }

    /// Action row owned by the chrome (not the card) so it's always
    /// visible regardless of card size. Hooks into the VM directly.
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
            if !viewModel.failedSources.isEmpty {
                Text(failureBadgeText)
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
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
