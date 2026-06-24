import SwiftUI

struct TrackRow: View {
    let track: LidarrTrackDetail

    /// Title colour. Flipped to match `EpisodeRow.episodeTitleStyle`
    /// post-redesign: on-disk tracks (your library, ready to play)
    /// take the brightest tone; missing tracks dim out from that
    /// baseline. Audio releases drop all at once so there's no
    /// "not aired" axis.
    private var trackTitleStyle: AnyShapeStyle {
        if track.hasFile == true { return AnyShapeStyle(Color.primary) }
        return AnyShapeStyle(Color.primary.opacity(0.75))
    }

    public var body: some View {
        // No hover affordance: a track isn't a navigation target (no
        // per-track detail), so it gets neither the series list's
        // chevron nor the old background-tint hover — just a static row.
        HStack(spacing: 6) {
            Text(track.trackNumber ?? String(track.absoluteTrackNumber ?? 0))
                .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .leading)
            // Text-colour signals state (matches EpisodeRow). No
            // status icons — audio releases either exist on disk or
            // they don't, the trailing duration + dim title carry
            // that bit without a green check / empty circle pair.
            Text(track.title ?? "—")
                .scaledFont(size: 11)
                .foregroundStyle(trackTitleStyle)
                .lineLimit(1)
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
