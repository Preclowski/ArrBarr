import SwiftUI

struct TrackRow: View {
    let track: LidarrTrackDetail
    /// Tap → per-track detail (file quality / size) — the audio counterpart
    /// of tapping an episode row.
    var onTap: (() -> Void)? = nil

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
            // Text-colour signals state (matches EpisodeRow). No
            // status icons — audio releases either exist on disk or
            // they don't, the trailing duration + dim title carry
            // that bit without a green check / empty circle pair.
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
