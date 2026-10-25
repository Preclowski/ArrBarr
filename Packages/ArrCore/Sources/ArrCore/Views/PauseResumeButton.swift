import SwiftUI

/// Pause/resume in the detail CTA strip: clear glass that fills with the download's progress.
/// `action` is async so the movie path gets a spinner; a sync body returns at once, so none flashes.
struct PauseResumeButton: View {
    let isPaused: Bool
    /// Nil where a real percentage isn't meaningful (Sonarr season packs): the glass stays clear.
    let progress: Double?
    let action: () async -> Void

    @State private var inFlight = false

    // The fill is the download, so it takes the status colour, like the progress card above it.
    private var tint: Color { (isPaused ? QueueItem.Status.paused : .downloading).tint }

    var body: some View {
        Button {
            guard !inFlight else { return }
            Task {
                inFlight = true
                await action()
                inFlight = false
            }
        } label: {
            HStack(spacing: 7) {
                // Only the glyph swaps for the spinner, so the button keeps its size.
                if inFlight {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: CTAButtonStyle.labelSize, height: CTAButtonStyle.labelSize)
                } else {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .frame(width: CTAButtonStyle.labelSize)
                }
                // Short verbs: the CTA strip fits three capsules.
                Text(isPaused
                        ? String(localized: "queue.resume.button", bundle: .module)
                        : String(localized: "queue.pause.button", bundle: .module))
            }
        }
        .buttonStyle(CTAButtonStyle(tint: tint, fill: progress ?? 0, flowing: !isPaused && progress != nil, glass: true))
        .disabled(inFlight)
        .animation(.easeInOut(duration: 0.3), value: isPaused)
    }
}
