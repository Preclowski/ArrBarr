import SwiftUI

/// Known arr availability/run states ("released", "inCinemas", "continuing",
/// …) mapped to localized labels; unknown values fall back to the
/// capitalized raw string. Shared by the Library tooltip and the movie
/// detail's existing-file banner so both spell the states identically.
enum ArrReleaseStatusLabel {
    static func text(_ raw: String?, locale: Locale) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let keys: [String: String] = [
            "tba": "library.release.tba",
            "announced": "library.release.announced",
            "incinemas": "library.release.inCinemas",
            "released": "library.release.released",
            "deleted": "library.release.deleted",
            "continuing": "library.release.continuing",
            "ended": "library.release.ended",
            "upcoming": "library.release.upcoming",
        ]
        if let key = keys[raw.lowercased()] {
            return AppLocalized.string(key, locale: locale)
        }
        return raw.capitalized
    }
}

/// Banner describing the file an arr already has on disk for this item —
/// built from `RadarrMovieDetail.movieFile` / similar.
struct ExistingFileBanner: View {
    let quality: String?
    let size: Int64?
    let customFormatScore: Int?
    let customFormats: [String]
    let fileName: String?
    /// Extra file facts, mirroring the Library tooltip (movie callers only —
    /// the queue/episode/track variants leave them nil).
    var releaseGroup: String?
    var languages: String?

    init(quality: String?, size: Int64?, customFormatScore: Int?,
         customFormats: [String], fileName: String?,
         releaseGroup: String? = nil, languages: String? = nil) {
        self.quality = quality; self.size = size
        self.customFormatScore = customFormatScore
        self.customFormats = customFormats
        self.fileName = fileName
        self.releaseGroup = releaseGroup
        self.languages = languages
    }

    /// Build the banner from an arr's library `movieFile` — the file the
    /// user already owns, no queue activity required. (Release status is a
    /// TITLE fact and lives in the hero card next to the library badge.)
    init(movieFile: ArrFile) {
        let languages = (movieFile.languages ?? []).compactMap(\.name)
        self.init(
            quality: movieFile.quality?.name,
            size: movieFile.size,
            customFormatScore: movieFile.customFormatScore,
            customFormats: (movieFile.customFormats ?? []).map(\.name),
            fileName: movieFile.relativePath,
            releaseGroup: movieFile.releaseGroup,
            languages: languages.isEmpty ? nil : languages.joined(separator: ", ")
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

    /// Lidarr `trackfile` variant — same chrome as movie / episode files.
    /// Lidarr sends an absolute `path` (no relativePath), so trim to the
    /// filename the same way the episode diff line does.
    init(trackFile: LidarrTrackFile) {
        self.init(
            quality: trackFile.quality?.quality?.name,
            size: trackFile.size,
            customFormatScore: trackFile.customFormatScore,
            customFormats: (trackFile.customFormats ?? []).map(\.name),
            fileName: trackFile.path.map { URL(fileURLWithPath: $0).lastPathComponent }
        )
    }

    public var body: some View {
        // Key-value grid for Jakość / Rozmiar / Ocena — the same labels,
        // order and styling as the download section's `UpgradeDiffTable`,
        // so the on-disk file and the incoming release read as the same
        // kind of table.
        VStack(alignment: .leading, spacing: 5) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                if let q = quality, !q.isEmpty {
                    GridRow {
                        label("queue.quality.button")
                        value(q, weight: .semibold)
                    }
                }
                if let s = size, s > 0 {
                    GridRow {
                        label("queue.size.button")
                        value(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                    }
                }
                // Same rows, same order as the Library tooltip: group,
                // languages, release status — then chips + filename below.
                if let releaseGroup, !releaseGroup.isEmpty {
                    GridRow {
                        label("Release group")
                        value(releaseGroup)
                    }
                }
                if let languages, !languages.isEmpty {
                    GridRow {
                        label("Languages")
                        value(languages)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Chips + filename carry no labels — self-describing values,
            // matching the download spec block (chip strip, then release
            // name, both full-width under the key-value grid). The score
            // rides as the strip's trailing chip — the same placement every
            // tooltip / queue row gives it (it used to be a labelled grid
            // row here, the one surface that differed).
            if !customFormats.isEmpty || (customFormatScore ?? 0) != 0 {
                TooltipFlowLayout(spacing: 4) {
                    ForEach(customFormats, id: \.self) { cf in
                        TagChip(text: cf, color: .primary)
                    }
                    if let score = customFormatScore, score != 0 {
                        ScoreChip(score: score)
                    }
                }
            }
            if let name = fileName, !name.isEmpty {
                // Never truncated; a lone filename renders primary (only the
                // old side of a diff goes secondary).
                Text(name)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private func value(_ text: String, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: weight)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .gridColumnAlignment(.leading)
    }
}
