import SwiftUI

/// Pause/resume with a small cancel beside it, under a detail whose title has one live download.
struct DownloadCTAStrip: View {
    let isPaused: Bool
    /// Nil when a percentage isn't meaningful; the pause button then stays clear.
    let progress: Double?
    let onToggle: () async -> Void
    /// Nil hides the cancel button.
    let onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            PauseResumeButton(isPaused: isPaused, progress: progress, action: onToggle)
                // The fill is visual only, so VoiceOver gets the completion as the value.
                .accessibilityValue(progress.map { Text(max(0.0, min(1.0, $0)), format: .percent.precision(.fractionLength(0))) } ?? Text(verbatim: ""))
            if let onCancel {
                // Small and icon-only so it can't be mistaken for the primary verb.
                Button {
                    PanelActivation.bringForward()
                    onCancel()
                } label: {
                    // Red on the glyph, not the glass: one coloured background per strip (HIG).
                    Image(systemName: "xmark")
                        .fontWeight(.bold)
                        .foregroundStyle(.red)
                        .frame(width: 18)
                        .frame(maxHeight: .infinity)
                }
                .buttonStyle(CTAButtonStyle(fullWidth: false, glass: true))
                .help(Text("queue.cancelDownload.button", bundle: .module))
                .accessibilityLabel(Text("queue.cancelDownload.button", bundle: .module))
                // "Cancel download" alone doesn't say the client loses the transfer.
                .accessibilityHint(Text("This will remove the download from the client.", bundle: .module))
            }
        }
        // A glyph is shorter than a text line; the cancel capsule takes the pause button's height.
        .fixedSize(horizontal: false, vertical: true)
    }
}
