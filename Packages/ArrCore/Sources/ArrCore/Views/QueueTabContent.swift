import SwiftUI

/// Search is not this view's business — `SearchHost` wraps it above the tabs.
struct QueueTabContent: View {
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore

    @Binding var detailItem: QueueItem?
    @Binding var historySource: QueueItem.Source?
    @Binding var selecting: Bool

    var body: some View {
        if viewModel.isLoading {
            ScrollView {
                loadingIndicator
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .padding(.bottom, 58)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        } else {
            QueueListView(
                viewModel: viewModel,
                onShowDetail: { item in
                    withAnimation(.smooth(duration: 0.22)) { detailItem = item }
                },
                onNeedsYouTap: { needs in openNeedsYouQueue(needs) },
                onShowHistory: { source in historySource = source },
                selecting: $selecting
            )
            // Keep the last row clear of the floating search capsule.
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 58) }
        }
    }

    private var loadingIndicator: some View { LoadingStateView() }

    private func openNeedsYouQueue(_ needs: NeedsYouItem) {
        // Non-arr issues (download client / AI) have no arr queue page; they're fixed in Settings.
        guard let source = needs.source else { return }
        let cfg = configStore.config(for: source.serviceKind)
        guard let url = ArrActivityURLBuilder.queueURL(forBase: cfg.baseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        PlatformURLOpener.open(url)
    }
}
