import SwiftUI

/// Full-width glass pause/resume CTA shared by the movie detail
/// (`DetailView`) and the episode detail (`EpisodeDetailOverlay`). Both used
/// to carry a ~95% identical copy of this button; the only real difference
/// was that the movie path runs async work (pause/resume + queue refresh)
/// and wants an in-flight spinner, while the episode path fires a sync
/// closure. Modelling `action` as `async` covers both: a sync body simply
/// returns immediately, so no spinner flashes.
struct PauseResumeButton: View {
    let isPaused: Bool
    /// Progress fill behind the glass (callers pass `1` where a real
    /// percentage isn't meaningful, e.g. Sonarr season packs).
    let progress: Double
    let tint: Color
    /// Tap handler. While it runs the button shows a spinner and disables
    /// itself — for sync work it just returns instantly.
    let action: () async -> Void

    @State private var inFlight = false

    // Touch target reads a little small on iOS — give it more height + type.
    #if os(iOS)
    private static let vPadding: CGFloat = 13
    private static let iconSize: CGFloat = 13
    private static let labelSize: CGFloat = 14
    #else
    private static let vPadding: CGFloat = 10
    private static let iconSize: CGFloat = 11
    private static let labelSize: CGFloat = 12
    #endif

    var body: some View {
        Button {
            guard !inFlight else { return }
            Task {
                inFlight = true
                await action()
                inFlight = false
            }
        } label: {
            HStack(spacing: 6) {
                if inFlight {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .scaledFont(size: Self.iconSize, weight: .semibold)
                    Text(isPaused
                            ? String(localized: "queue.resumeDownload.button", bundle: .module)
                            : String(localized: "detail.pauseDownload.button", bundle: .module))
                        .scaledFont(size: Self.labelSize, weight: .semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Self.vPadding)
            .padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
        .disabled(inFlight)
        .liquidGlassProgressCTA(progress: progress, tint: tint)
    }
}
