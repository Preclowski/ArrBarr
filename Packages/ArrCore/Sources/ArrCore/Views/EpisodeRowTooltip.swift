import SwiftUI

/// Long-hover popover for episode rows. Surfaces the *quality
/// context* the row can't fit inline — full quality string, size,
/// custom-format score, and the `└─ OLD` line for upgrade-in-flight
/// rows where the user wants to see what's getting replaced.
struct EpisodeRowTooltip: View {
    let episode: SonarrEpisodeDetail
    let queueItem: QueueItem?
    let episodeFile: SonarrEpisodeFile?
    let seriesTitle: String?
    let seriesPosterURL: URL?
    let seriesPosterRequiresAuth: Bool
    let seriesPosterAPIKey: String?
    @EnvironmentObject var configStore: ConfigStore

    public init(
        episode: SonarrEpisodeDetail,
        queueItem: QueueItem?,
        episodeFile: SonarrEpisodeFile?,
        seriesTitle: String? = nil,
        seriesPosterURL: URL? = nil,
        seriesPosterRequiresAuth: Bool = false,
        seriesPosterAPIKey: String? = nil
    ) {
        self.episode = episode
        self.queueItem = queueItem
        self.episodeFile = episodeFile
        self.seriesTitle = seriesTitle
        self.seriesPosterURL = seriesPosterURL
        self.seriesPosterRequiresAuth = seriesPosterRequiresAuth
        self.seriesPosterAPIKey = seriesPosterAPIKey
    }

    var body: some View {
        // Queue-tooltip content shape (header + divider + grid +
        // chips) without the poster — the user is already inside
        // the series detail surface, the show's poster is right
        // there in the hero card and would duplicate.
        tooltipContent
            .padding(12)
            // 358pt = queue tooltip width (480) minus poster (110)
            // and HStack spacing (12) — the content column lives at
            // the same pixel width whether or not the poster is on
            // its left.
            .frame(width: 358, alignment: .leading)
    }

    private var tooltipContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let q = queueItem, q.isUpgrade, let file = episodeFile {
                // Active upgrade — render the same side-by-side diff
                // (quality/score/size + gained/lost format chips + both
                // file names) every other surface uses, so the Sonarr
                // episode tooltip reads identically to the movie/album
                // detail and the single-item queue tooltip. UpgradeDiffView
                // already carries the CF chip diff and the release / on-disk
                // file names, so no separate chip strip is needed here.
                upgradeDiffBlock(new: q, existing: file)
            } else {
                infoGrid
                if let formats = primaryFormats, !formats.isEmpty {
                    customFormatChipStrip(
                        tags: formats,
                        score: primaryScore != 0 ? primaryScore : nil
                    )
                }
            }
        }
    }

    /// Upgrade-in-flight body: a compact status + client line above the
    /// shared `UpgradeDiffView`. Feeds the on-disk `episodeFile` as the
    /// "current" side and the queued release as the "incoming" side so
    /// both file names render (Sonarr ships the existing file separately
    /// from the queue record, hence the `episodeFile` join here).
    @ViewBuilder
    private func upgradeDiffBlock(new q: QueueItem, existing file: SonarrEpisodeFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusIconLabel(status: q.status,
                                iconSize: 10,
                                labelSize: 11,
                                labelWeight: .semibold)
                if let client = q.downloadClient {
                    DownloadClientLabel(name: client)
                }
                Spacer(minLength: 0)
            }
            UpgradeDiffView(
                current: .init(
                    quality: file.quality?.name,
                    score: file.customFormatScore,
                    size: file.size,
                    formats: (file.customFormats ?? []).map(\.name),
                    // Match the queue path's `existingFileName` (last path
                    // component) so the old name reads the same whether the
                    // user is on the tooltip, the episode detail, or the
                    // queue list.
                    filename: file.relativePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                ),
                incoming: .init(
                    quality: q.quality,
                    score: q.customFormatScore,
                    size: q.sizeTotal > 0 ? q.sizeTotal : nil,
                    formats: q.customFormats,
                    filename: q.releaseName
                ),
                showFilenames: true
            )
        }
    }

    /// Formats to show in the chip strip — queue item's tags if a
    /// download is in flight, otherwise the on-disk file's tags.
    private var primaryFormats: [String]? {
        if let q = queueItem { return q.customFormats }
        if let file = episodeFile {
            return (file.customFormats ?? []).map(\.name)
        }
        return nil
    }

    private var primaryScore: Int {
        queueItem?.customFormatScore ?? episodeFile?.customFormatScore ?? 0
    }

    private var existingFormats: [String] {
        (episodeFile?.customFormats ?? []).map(\.name)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Series title + Upgrade/New badge sit on the same line —
            // mirrors `QueueItemTooltip.header`'s "title + badge"
            // arrangement.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(seriesTitle ?? episode.title ?? "—")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let q = queueItem {
                    MediaBadgeCluster(isUpgrade: q.isUpgrade)
                }
                Spacer(minLength: 4)
            }
            // Subtitle = "Season 02 · Episode 04 — Cold Start".
            // Same shape as queue rows' subtitle, builds the
            // "what season / episode am I looking at" answer in
            // one glance.
            Text(seasonEpisodeSubtitle)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var seasonEpisodeSubtitle: String {
        var bits: [String] = []
        if let sn = episode.seasonNumber {
            bits.append(String(format: "Season %02d", sn))
        }
        if let en = episode.episodeNumber {
            bits.append(String(format: "Episode %02d", en))
        }
        let prefix = bits.joined(separator: " · ")
        if let t = episode.title, !t.isEmpty, seriesTitle != nil {
            return prefix.isEmpty ? t : "\(prefix) — \(t)"
        }
        return prefix
    }

    @ViewBuilder
    private var infoGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            if let q = queueItem {
                gridRow(label: "Status") {
                    HStack(spacing: 4) {
                        StatusIconLabel(status: q.status,
                                        iconSize: 10,
                                        labelSize: 11,
                                        labelWeight: .semibold)
                    }
                }
                gridRow(label: "Quality") {
                    qualitySizeScore(
                        quality: q.quality,
                        size: q.sizeTotal,
                        score: q.customFormatScore
                    )
                }
                if let file = episodeFile, q.isUpgrade {
                    GridRow(alignment: .firstTextBaseline) {
                        Color.clear.frame(width: 0, height: 0)
                        ExistingFileDiffRow(
                            existingQuality: file.quality?.name,
                            existingSize: file.size,
                            existingScore: file.customFormatScore,
                            newScore: q.customFormatScore,
                            newQuality: q.quality,
                            newSize: q.sizeTotal > 0 ? q.sizeTotal : nil,
                            tagsDiffer: Set(q.customFormats) != Set(existingFormats)
                        )
                    }
                }
                if let client = q.downloadClient {
                    gridRow(label: "Client") {
                        Text(client).scaledFont(size: 11).foregroundStyle(.secondary)
                    }
                }
            } else if let file = episodeFile {
                gridRow(label: "On disk") {
                    qualitySizeScore(
                        quality: file.quality?.name,
                        size: file.size ?? 0,
                        score: file.customFormatScore ?? 0
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func gridRow<Value: View>(label: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label, bundle: .module)
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.4)
                .gridColumnAlignment(.leading)
            value()
        }
    }

    @ViewBuilder
    private func qualitySizeScore(quality: String?, size: Int64, score: Int) -> some View {
        HStack(spacing: 4) {
            if let q = quality, !q.isEmpty {
                Text(q)
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.primary)
            }
            if size > 0 {
                if quality?.isEmpty == false {
                    SeparatorDot()
                }
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            if score != 0 {
                SeparatorDot()
                ScoreLabel(score: score, size: 11)
            }
        }
    }

}
