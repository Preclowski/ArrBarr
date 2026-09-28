import SwiftUI

extension DetailView {
    // MARK: - Download CTA strip
    @ViewBuilder
    var downloadCTAStrip: some View {
        let hasDownloadControls = hasActiveDownloads && canControl
        if hasDownloadControls, canPauseResume {
            HStack(spacing: 8) {
                pauseResumeProminent
                // Small and icon-only so it can't be mistaken for the primary verb.
                cancelGlassCompact
            }
            // The inline confirm is attached to body so the toolbar trash can use it too.
        }
    }

    private enum CancelCTAMetrics {
        #if os(iOS)
        static let vPadding: CGFloat = 13
        static let glyph: CGFloat = 14
        #else
        static let vPadding: CGFloat = 7
        static let glyph: CGFloat = 13
        #endif
    }

    private var cancelGlassCompact: some View {
        Button {
            PanelActivation.bringForward(); ctaPendingDelete = true
        } label: {
            Image(systemName: "xmark")
                .scaledFont(size: CancelCTAMetrics.glyph, weight: .bold)
                .foregroundStyle(.red)
                .frame(width: 26)
                // Must match `PauseResumeButton`'s padding, or the two buttons differ in height.
                .padding(.vertical, CancelCTAMetrics.vPadding)
        }
        .modifier(GlassTintedButtonStyle())
        .tint(.red)
        .help(Text("queue.cancelDownload.button", bundle: .module))
        .accessibilityLabel(Text("queue.cancelDownload.button", bundle: .module))
    }

    // MARK: - CTA strip sub-views

    @ViewBuilder
    private var pauseResumeProminent: some View {
        let f = focused
        let showsPlay = focusedShowsPlay
        PauseResumeButton(
            isPaused: showsPlay,
            progress: f.source == .sonarr ? 1 : f.progress,
            // Tint by the action, not the status; red stays Cancel's.
            tint: showsPlay ? .blue : .orange
        ) {
            if showsPlay {
                await viewModel.resume(f)
            } else {
                await viewModel.pause(f)
            }
            // Poll now so the status flip lands before the spinner releases, or the label reverts
            // until the next scheduled refresh.
            await viewModel.refresh()
        }
    }
}
