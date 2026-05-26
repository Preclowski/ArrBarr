import SwiftUI

/// Banner describing the file an arr already has on disk for this item.
/// Two callers:
///   - upgrade-in-progress (queue item) — fields come from the queue
///     row's `existing*` metadata
///   - already-in-library (no active queue) — fields come from
///     `RadarrMovieDetail.movieFile` / similar
/// The view body is the same; only the source of the fields differs.
struct ExistingFileBanner: View {
    let quality: String?
    let size: Int64?
    let customFormatScore: Int?
    let customFormats: [String]
    let fileName: String?

    init(quality: String?, size: Int64?, customFormatScore: Int?,
         customFormats: [String], fileName: String?) {
        self.quality = quality; self.size = size
        self.customFormatScore = customFormatScore
        self.customFormats = customFormats
        self.fileName = fileName
    }

    /// Build the banner from a queue row's `existing*` fields (upgrade-time
    /// metadata Radarr/Sonarr send when a download will replace something).
    init(item: QueueItem) {
        self.init(
            quality: item.existingQuality,
            size: item.existingSize,
            customFormatScore: item.existingCustomFormatScore,
            customFormats: item.existingCustomFormats,
            fileName: item.existingFileName
        )
    }

    /// Build the banner from an arr's library `movieFile` — the file the
    /// user already owns, no queue activity required.
    init(movieFile: ArrFile) {
        self.init(
            quality: movieFile.quality?.name,
            size: movieFile.size,
            customFormatScore: movieFile.customFormatScore,
            customFormats: (movieFile.customFormats ?? []).map(\.name),
            fileName: movieFile.relativePath
        )
    }

    /// Sonarr `episodefile` variant — same payload as `ArrFile` plus
    /// an `id` we don't need here. Lets `EpisodeDetailOverlay` build
    /// the banner from the already-loaded `sonarrEpisodeFiles` map
    /// instead of a separate per-episode fetch.
    init(episodeFile: SonarrEpisodeFile) {
        self.init(
            quality: episodeFile.quality?.name,
            size: episodeFile.size,
            customFormatScore: episodeFile.customFormatScore,
            customFormats: (episodeFile.customFormats ?? []).map(\.name),
            fileName: episodeFile.relativePath
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Label leading, neutral secondary — matches the tooltip's
            // `existingFileSummary`. Quality/size/score follow on the
            // right edge.
            HStack(spacing: 6) {
                Text("Existing file", bundle: .module)
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if let q = quality, !q.isEmpty {
                    Text(q)
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(.primary)
                }
                if let size, size > 0 {
                    SeparatorDot()
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                if let s = customFormatScore, s != 0 {
                    SeparatorDot()
                    ScoreLabel(score: s, size: 11)
                }
            }
            // Filename now sits directly under the header (was last in
            // the stack — bumped up because "what file is on disk" is
            // the natural follow-up to "EXISTING FILE", more so than
            // its custom-format tags). Promoted from tertiary 10pt to
            // secondary 11pt so it reads as primary content, not a
            // footnote.
            if let name = fileName, !name.isEmpty {
                Text(name)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !customFormats.isEmpty {
                TooltipFlowLayout(spacing: 4) {
                    ForEach(customFormats, id: \.self) { TagChip(text: $0) }
                }
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No tinted card — the indigo "↑ EXISTING FILE" label on the
        // trailing edge already brands the section; an additional
        // indigo background dropped chip contrast and broke visual
        // consistency with the same section inside the tooltip.
    }
}
