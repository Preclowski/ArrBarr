import SwiftUI

/// Shared by `DetailView` and `EpisodeDetailOverlay`. `action` is async so the movie path gets a spinner;
/// a sync body returns at once, so none flashes.
struct PauseResumeButton: View {
    let isPaused: Bool
    /// Callers pass `1` where a real percentage isn't meaningful (Sonarr season packs).
    let progress: Double
    let tint: Color
    let action: () async -> Void

    @State private var inFlight = false

    // Touch target reads a little small on iOS — give it more height + type.
    #if os(iOS)
    private static let vPadding: CGFloat = 13
    private static let labelSize: CGFloat = 14
    #else
    // 7pt to match the Manual-search / Cancel CTAs exactly (same capsule height).
    private static let vPadding: CGFloat = 7
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
                // Only the glyph swaps for the spinner, so the button keeps its size.
                if inFlight {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: Self.labelSize + 2, height: Self.labelSize + 2)
                } else {
                    DownloadProgressRing(
                        systemName: isPaused ? "play.fill" : "pause.fill",
                        progress: progress,
                        // Match the text line height so the ring doesn't make the
                        // capsule taller than the Cancel button beside it.
                        diameter: Self.labelSize + 2
                    )
                }
                // Short verbs: the CTA strip fits three capsules.
                Text(isPaused
                        ? String(localized: "queue.resume.button", bundle: .module)
                        : String(localized: "queue.pause.button", bundle: .module))
                    .scaledFont(size: Self.labelSize, weight: .semibold)
            }
            // On translucent glass a white label has nothing to sit on; the status colour is the signal.
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Self.vPadding)
        }
        // Translucent glass, not the filled prominent style: a solid capsule over artwork reads as a slab.
        .modifier(GlassButtonStyle())
        .tint(tint)
        .disabled(inFlight)
    }
}
