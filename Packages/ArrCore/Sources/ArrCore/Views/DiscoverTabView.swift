import SwiftUI

public struct DiscoverTabView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let onAddToRadarr: (SearchResult) -> Void
    let onOpenDetail: (DiscoverItem, Int) -> Void

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
            DiscoverFilterBar(
                filter: Binding(get: { viewModel.filter },
                                set: { viewModel.filter = $0 }),
                moodText: Binding(get: { viewModel.moodText },
                                  set: { viewModel.moodText = $0 }),
                llmAvailable: llmAvailable,
                onReshuffle: { Task { await viewModel.reshuffle() } }
            )
            Divider()

            ScrollView {
                content
                    .padding(.vertical, 12)
            }
        }
        .task(id: filterFingerprint) {
            await viewModel.reshuffle()
        }
        .onChange(of: viewModel.pendingAction) { _, action in
            guard let action, let item = viewModel.pendingActionItem else { return }
            switch action {
            case .addToRadarr:
                onAddToRadarr(item.result)
            case .openDetail(let arrId):
                onOpenDetail(item, arrId)
            }
            viewModel.clearPendingAction()
        }
    }

    /// Hash of inputs that should trigger a reshuffle. Used as `task(id:)`
    /// so SwiftUI re-runs the fetch when filter or mood change.
    private var filterFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(viewModel.filter.decade)
        hasher.combine(viewModel.filter.monitoredOnly)
        hasher.combine(viewModel.moodText)
        return hasher.finalize()
    }

    @ViewBuilder
    private var content: some View {
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
            VStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .scaledFont(size: 22, weight: .light)
                    .foregroundStyle(.tertiary)
                Text("No more cards", bundle: .module)
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
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
