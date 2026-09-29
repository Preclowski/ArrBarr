import SwiftUI

extension DetailView {
    @ViewBuilder
    var downloadCTAStrip: some View {
        if hasActiveDownloads, canControl, canPauseResume {
            let f = focused
            let showsPlay = focusedShowsPlay
            DownloadCTAStrip(
                isPaused: showsPlay,
                progress: f.source == .sonarr ? 1 : f.progress,
                onToggle: {
                    if showsPlay { await viewModel.resume(f) } else { await viewModel.pause(f) }
                    // Poll now so the status flip lands before the spinner releases, or the label reverts
                    // until the next scheduled refresh.
                    await viewModel.refresh()
                },
                // The inline confirm is attached to body so the toolbar trash can use it too.
                onCancel: { ctaPendingDelete = true }
            )
        }
    }
}
