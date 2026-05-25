import SwiftUI

public struct DiscoverTabView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let onAddToRadarr: (SearchResult) -> Void
    let onOpenDetail: (DiscoverItem, Int) -> Void

    @State private var showMatched: Bool = false

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                onAddToRadarr: @escaping (SearchResult) -> Void,
                onOpenDetail: @escaping (DiscoverItem, Int) -> Void) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
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
                ScrollView {
                    swipingContent.padding(.vertical, 12)
                }
            }
        }
        .task(id: filterFingerprint) {
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
                moodText: Binding(get: { viewModel.moodText },
                                  set: { viewModel.moodText = $0 }),
                llmAvailable: llmAvailable,
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

    private var filterFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(viewModel.filter.decade)
        hasher.combine(viewModel.filter.monitoredOnly)
        hasher.combine(viewModel.moodText)
        return hasher.finalize()
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
            ProgressView().controlSize(.small).padding(.top, 40)
        } else if let item = viewModel.current {
            DiscoverCardView(
                item: item,
                onSwipeRight: { Task { await viewModel.swipe(right: true) } },
                onSwipeLeft:  { Task { await viewModel.swipe(right: false) } }
            )
            .padding(.horizontal, 12)
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
                .padding(.top, 6)
            }
            if !viewModel.failedSources.isEmpty {
                Text(failureBadgeText)
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
        } else {
            // When swiping is exhausted but matches exist, nudge user
            // toward their picks list.
            VStack(spacing: 6) {
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
            }
            .padding(.top, 60)
        }
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
