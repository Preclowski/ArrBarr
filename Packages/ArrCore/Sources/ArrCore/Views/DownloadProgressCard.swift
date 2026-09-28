import SwiftUI

/// Progress block for any download: status header, bar, optional upgrade diff,
/// on a status-tinted background whose fill scales with progress.
struct DownloadProgressCard: View {
    let item: QueueItem
    /// Aggregate progress for season-pack rows; nil uses `item.progress`.
    let progressOverride: Double?
    let showUpgradeDiff: Bool
    let showHeader: Bool
    /// Detail surfaces show the status row on `DownloadingSectionHeader` instead.
    let showStatusRow: Bool
    /// Queue rows: `quality · size` inline next to the status pill.
    let compactSpec: Bool
    /// Sonarr ships existing-file metadata only via `/episodefile/{id}`, not on the queue item.
    let existingOverride: ExistingFileSnapshot?

    struct ExistingFileSnapshot {
        let quality: String?
        let size: Int64?
        let score: Int?
        let formats: [String]
        let filename: String?
        init(quality: String?, size: Int64?, score: Int?, formats: [String], filename: String? = nil) {
            self.quality = quality
            self.size = size
            self.score = score
            self.formats = formats
            self.filename = filename
        }
    }

    init(
        item: QueueItem,
        progressOverride: Double? = nil,
        showUpgradeDiff: Bool = true,
        showHeader: Bool = false,
        showStatusRow: Bool = true,
        compactSpec: Bool = false,
        existingOverride: ExistingFileSnapshot? = nil
    ) {
        self.item = item
        self.progressOverride = progressOverride
        self.showUpgradeDiff = showUpgradeDiff
        self.showHeader = showHeader
        self.showStatusRow = showStatusRow
        self.compactSpec = compactSpec
        self.existingOverride = existingOverride
    }

    private var tint: Color { item.status.tint }
    private var effectiveExistingQuality: String? {
        existingOverride?.quality ?? item.existingQuality
    }
    private var effectiveExistingSize: Int64? {
        existingOverride?.size ?? item.existingSize
    }
    private var effectiveExistingScore: Int? {
        existingOverride?.score ?? item.existingCustomFormatScore
    }
    private var effectiveExistingFormats: [String] {
        existingOverride?.formats ?? item.existingCustomFormats
    }
    private var effectiveExistingFilename: String? {
        existingOverride?.filename ?? item.existingFileName
    }
    private var willShowDiff: Bool {
        guard showUpgradeDiff else { return false }
        // An explicit override is only passed in upgrade contexts.
        if existingOverride != nil { return hasExistingMetadata }
        return item.isUpgrade && hasExistingMetadata
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showHeader {
                if showStatusRow {
                    HStack(spacing: 6) {
                        DownloadStatusCluster(item: item, showUpgradeBadge: !compactSpec)
                        Spacer(minLength: 6)
                        if compactSpec {
                            inlineSpec
                        }
                    }
                }
                if !compactSpec {
                    // A real upgrade renders the side-by-side `UpgradeDiffView` from the `effective*` values
                    // (so Sonarr's `existingOverride` counts); a new download keeps the `UpgradeDiffTable` spec grid.
                    Group {
                        if willShowDiff {
                            UpgradeDiffView(
                                current: .init(
                                    quality: effectiveExistingQuality,
                                    score: effectiveExistingScore,
                                    size: effectiveExistingSize,
                                    formats: effectiveExistingFormats,
                                    filename: effectiveExistingFilename
                                ),
                                incoming: .init(
                                    quality: item.quality,
                                    score: item.customFormatScore,
                                    size: item.sizeTotal > 0 ? item.sizeTotal : nil,
                                    formats: item.customFormats,
                                    filename: item.releaseName
                                ),
                                showFilenames: true
                            )
                        } else {
                            UpgradeDiffTable(
                                newQuality: item.quality,
                                newSize: item.sizeTotal > 0 ? item.sizeTotal : nil,
                                newScore: item.customFormatScore,
                                oldQuality: nil,
                                oldSize: nil,
                                oldScore: nil,
                                newFormats: [],
                                oldFormats: [],
                                newFilename: nil,
                                oldFilename: nil,
                                indexer: item.indexer,
                                tint: tint
                            )
                        }
                    }
                    .padding(.top, 5)

                    if willShowDiff, let indexer = item.indexer, !indexer.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Indexer", bundle: .module)
                                .scaledFont(size: 11, weight: .semibold)
                                .foregroundStyle(.secondary)
                            Text(indexer)
                                .scaledFont(size: 11)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            progressBarWithPercent
        }
    }

    @ViewBuilder
    private var progressBarWithPercent: some View {
        // Detail surfaces drop the bar; progress shows in their Resume/Pause CTA.
        if compactSpec {
            LiveProgress(item: item) { live in
                ThinProgressBar(progress: progressOverride ?? live, tint: tint, height: 6)
            }
        }
    }

    @ViewBuilder
    private var inlineSpec: some View {
        HStack(spacing: 3) {
            if let q = item.quality, !q.isEmpty {
                Text(q)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
            if item.sizeTotal > 0 {
                if item.quality?.isEmpty == false {
                    SeparatorDot()
                }
                Text(ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file))
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var hasExistingMetadata: Bool {
        (effectiveExistingQuality.map { !$0.isEmpty } ?? false)
            || (effectiveExistingSize ?? 0) > 0
            || (effectiveExistingScore ?? 0) != 0
    }
}


/// Separate from the card because detail surfaces put it on the "Downloading" section header.
struct DownloadStatusCluster: View {
    let item: QueueItem
    var showUpgradeBadge: Bool = true

    init(item: QueueItem, showUpgradeBadge: Bool = true) {
        self.item = item
        self.showUpgradeBadge = showUpgradeBadge
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusIconLabel(status: item.status)
            if showUpgradeBadge {
                MediaBadgeCluster(isUpgrade: item.isUpgrade)
            }
            if let client = item.downloadClient {
                DownloadClientLabel(name: client)
            }
        }
    }
}

struct DownloadingSectionHeader: View {
    let item: QueueItem

    init(item: QueueItem) { self.item = item }

    var body: some View {
        HStack(spacing: 8) {
            DetailSectionHeader("Downloading")
                // The title truncates rather than a status word wrapping inside its capsule.
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 6)
            DownloadStatusCluster(item: item)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
