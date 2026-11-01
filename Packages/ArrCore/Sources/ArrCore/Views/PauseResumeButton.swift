import SwiftUI

/// Pause/resume in the detail CTA strip: clear glass that fills with the download's progress.
/// `action` is async so the movie path gets a spinner; a sync body returns at once, so none flashes.
struct PauseResumeButton: View {
    let isPaused: Bool
    /// Nil where a real percentage isn't meaningful (Sonarr season packs): the glass stays clear.
    let progress: Double?
    let action: () async -> Void

    @State private var inFlight = false
    /// The write is optimistic, so the state flips under the spinner: the old glyph waits there and morphs as it leaves.
    @State private var pausedBeforeAction = false

    private var showsPlay: Bool { inFlight ? pausedBeforeAction : isPaused }

    // The fill is the download, so it takes the status colour, like the progress card above it.
    private var tint: Color { (isPaused ? QueueItem.Status.paused : .downloading).tint }

    var body: some View {
        Button {
            guard !inFlight else { return }
            pausedBeforeAction = isPaused
            Task {
                inFlight = true
                await action()
                inFlight = false
            }
        } label: {
            HStack(spacing: 7) {
                // Only the glyph swaps for the spinner, so the button keeps its size.
                ZStack {
                    Image(systemName: showsPlay ? "play.fill" : "pause.fill")
                        .symbolSwap()
                        .frame(width: CTAButtonStyle.labelSize)
                        .opacity(inFlight ? 0 : 1)
                    if inFlight {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: CTAButtonStyle.labelSize, height: CTAButtonStyle.labelSize)
                    }
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
        .animation(.easeInOut(duration: 0.3), value: showsPlay)
    }
}
