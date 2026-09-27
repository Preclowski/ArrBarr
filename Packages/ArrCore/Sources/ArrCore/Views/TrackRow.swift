import SwiftUI
import MediaKit

struct TrackRow: View {
    let track: ArrTrack
    var onTap: (() -> Void)? = nil

    /// Matches `EpisodeRow.episodeTitleStyle`: on-disk tracks brightest, missing ones dimmed.
    private var trackTitleStyle: AnyShapeStyle {
        if track.hasFile == true { return AnyShapeStyle(Color.primary) }
        return AnyShapeStyle(Color.primary.opacity(0.75))
    }

    var body: some View {
        Button { onTap?() } label: { row.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .linkRowHover()
    }

    private var row: some View {
        HStack(spacing: 6) {
            Text(track.trackNumber ?? String(track.absoluteTrackNumber ?? 0))
                .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .leading)
            // No status icons: a track is on disk or not, and the dimmed title carries that.
            Text(track.title ?? "—")
                .scaledFont(size: 11)
                .foregroundStyle(trackTitleStyle)
                .lineLimit(1)
            LinkChevron(size: 8)
            Spacer()
            if let dur = track.duration, dur > 0 {
                Text(formatDuration(ms: dur))
                    .scaledFont(size: 10, monospacedDigit: true)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}
