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
                // Only the glyph swaps for the in-flight spinner — the label stays
                // put so the button keeps its size/text while loading, then updates
                // in place once the action lands.
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
                // Short verbs ("Resume"/"Pause", not "Resume download") — the
                // CTA strip fits three capsules, long labels truncated.
                Text(isPaused
                        ? String(localized: "queue.resume.button", bundle: .module)
                        : String(localized: "queue.pause.button", bundle: .module))
                    .scaledFont(size: Self.labelSize, weight: .semibold)
            }
            // Force white — `.glassProminent` flips to black text on light
            // tints (green/orange), which clashed with the white-labelled
            // Search/Cancel capsules beside it.
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Self.vPadding)
        }
        // Same prominent glass capsule as the "Manual search" / Delete CTAs;
        // status tint distinguishes a paused vs active download. Progress reads
        // off the circular ring around the glyph, not a capsule fill.
        .modifier(GlassProminentButtonStyle())
        .tint(tint)
        .disabled(inFlight)
    }
}
