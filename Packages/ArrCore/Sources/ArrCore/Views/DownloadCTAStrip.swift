import SwiftUI

/// Pause/resume with a small cancel beside it, under a detail whose title has one live download.
struct DownloadCTAStrip: View {
    let isPaused: Bool
    let progress: Double
    let onToggle: () async -> Void
    /// Nil hides the cancel button.
    let onCancel: (() -> Void)?

    private enum Metrics {
        #if os(iOS)
        static let vPadding: CGFloat = 13
        static let glyph: CGFloat = 14
        #else
        static let vPadding: CGFloat = 7
        static let glyph: CGFloat = 13
        #endif
    }

    var body: some View {
        HStack(spacing: 8) {
            // Tint by the action, not the status; red stays Cancel's.
            PauseResumeButton(isPaused: isPaused, progress: progress, tint: isPaused ? .blue : .orange, action: onToggle)
                // The ring is the only place this completion shows, so VoiceOver gets it as the value.
                .accessibilityValue(Text(max(0.0, min(1.0, progress)), format: .percent.precision(.fractionLength(0))))
            if let onCancel {
                // Small and icon-only so it can't be mistaken for the primary verb.
                Button {
                    PanelActivation.bringForward()
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(size: Metrics.glyph, weight: .bold)
                        .foregroundStyle(.red)
                        .frame(width: 26)
                        // Must match `PauseResumeButton`'s padding, or the two buttons differ in height.
                        .padding(.vertical, Metrics.vPadding)
                }
                .modifier(GlassTintedButtonStyle())
                .tint(.red)
                .help(Text("queue.cancelDownload.button", bundle: .module))
                .accessibilityLabel(Text("queue.cancelDownload.button", bundle: .module))
                // "Cancel download" alone doesn't say the client loses the transfer.
                .accessibilityHint(Text("This will remove the download from the client.", bundle: .module))
            }
        }
    }
}
