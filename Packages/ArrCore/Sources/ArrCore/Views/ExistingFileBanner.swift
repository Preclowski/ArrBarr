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
    /// When set, chips in `customFormats` that aren't in this list
    /// render as removed (red outline) — they're the formats the
    /// new download will strip. Nil for "no active upgrade, just
    /// show what's on disk" callers, where every chip stays neutral.
    /// Symmetric to `CustomFormatChips.existingFormats` which colours
    /// chips green when they're net-new vs the existing file.
    var newFormats: [String]?
    /// Show the quality (+ size) line. False for the upgrade-in-progress caller,
    /// where `DownloadProgressCard`'s `└─ OLD` sub-line already prints quality —
    /// printing it here too would duplicate. True for the "already in library /
    /// upcoming" callers, where this banner is the ONLY place quality appears, so
    /// omitting it made the detail look broken (filename + formats but no quality).
    var showMetadata: Bool

    init(quality: String?, size: Int64?, customFormatScore: Int?,
         customFormats: [String], fileName: String?, newFormats: [String]? = nil,
         showMetadata: Bool = false) {
        self.quality = quality; self.size = size
        self.customFormatScore = customFormatScore
        self.customFormats = customFormats
        self.fileName = fileName
        self.newFormats = newFormats
        self.showMetadata = showMetadata
    }

    /// Build the banner from a queue row's `existing*` fields (upgrade-time
    /// metadata Radarr/Sonarr send when a download will replace something).
    /// Pass `comparingTo: item.customFormats` to colour-code removed
    /// chips red (the diff view); omit for a plain "this is on disk"
    /// banner with all chips neutral.
    init(item: QueueItem, comparingTo newFormats: [String]? = nil) {
        self.init(
            quality: item.existingQuality,
            size: item.existingSize,
            customFormatScore: item.existingCustomFormatScore,
            customFormats: item.existingCustomFormats,
            fileName: item.existingFileName,
            newFormats: newFormats
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
            fileName: movieFile.relativePath,
            showMetadata: true
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
            fileName: episodeFile.relativePath,
            showMetadata: true
        )
    }

    public var body: some View {
        // No header label, no inline metadata strip — same chrome as
        // the new-release block above (filename + chip strip). The
        // "EXISTING FILE" caption it used to crown was carrying its
        // weight only as a section divider, and the file's own
        // quality/size/score is already visible inside
        // DownloadProgressCard's `└─ OLD` upgrade sub-line. Symmetric
        // siblings: one block for the incoming release, one for the
        // one on disk, both styled identically.
        VStack(alignment: .leading, spacing: 5) {
            if showMetadata, (quality?.isEmpty == false) || size != nil || (customFormatScore ?? 0) != 0 {
                HStack(spacing: 6) {
                    if let q = quality, !q.isEmpty {
                        Text(q)
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(.primary)
                    }
                    if let s = size, s > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    if let score = customFormatScore, score != 0 {
                        Text(verbatim: score > 0 ? "+\(score)" : "\(score)")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(score > 0 ? .green : .red)
                            .help(Text("common.customFormatScore.button", bundle: .module))
                    }
                }
            }
            if let name = fileName, !name.isEmpty {
                Text(name)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !customFormats.isEmpty {
                let newSet: Set<String> = newFormats.map(Set.init) ?? []
                let highlightRemoved = newFormats != nil
                TooltipFlowLayout(spacing: 4) {
                    ForEach(customFormats, id: \.self) { cf in
                        // Mirror of CustomFormatChips' green-for-added:
                        // red-for-going-away. Chips kept across the
                        // upgrade stay neutral. Without `newFormats`
                        // (no diff context), all chips neutral — that's
                        // the "in library, no active download" view.
                        let isRemoved = highlightRemoved && !newSet.contains(cf)
                        TagChip(text: cf, color: isRemoved ? .red : .primary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
