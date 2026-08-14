import SwiftUI

/// Unified rounded-corner card wrapping any download's progress
/// block — status pill + percent + score on top, thin progress bar
/// below, optional upgrade-diff sub-row, all inside a status-tinted
/// rounded background whose fill scales with progress. Drop-in
/// replacement for the inline `StatusIconLabel + ThinProgressBar`
/// pairs scattered across queue rows, season-pack rows, the detail
/// `DownloadSection`, and the episode-detail file section.
///
/// One card visual = one place to tweak it. Adding warnings banner,
/// release-name footer, or any other download-context decoration
/// stays the responsibility of the surrounding container so the
/// card itself stays focused on the progress narrative.
public struct DownloadProgressCard: View {
    let item: QueueItem
    /// Override the displayed progress — used by season-pack rows
    /// where the rendered % is an *aggregate* over member items, not
    /// the representative's own progress. nil = use `item.progress`.
    let progressOverride: Double?
    /// Show the inline upgrade diff sub-line (`└─ OLD: quality · size (±delta)`).
    /// Defaults to true; surfaces that already render an explicit
    /// existing-file section can pass false.
    let showUpgradeDiff: Bool
    /// Render the status icon + label / percent / score header above
    /// the bar. Queue-row variants set `false` because the row
    /// already shows status info inline above the card.
    let showHeader: Bool
    /// Queue-row variant: inline `quality · size · score` next to
    /// the status pill instead of on its own row. Keeps the compact
    /// list dense. Detail surfaces stay false (spec gets its own
    /// row so the diff sub-line reads as a vertical continuation).
    let compactSpec: Bool
    /// Side-channel "existing file" payload for arrs that don't pack
    /// the existing metadata into the QueueItem (Sonarr ships it via
    /// `/episodefile/{id}` only). When non-nil, this overrides
    /// `item.existing*` so the in-card diff line renders the same
    /// `↑` row as the movie/album path.
    let existingOverride: ExistingFileSnapshot?

    public struct ExistingFileSnapshot {
        public let quality: String?
        public let size: Int64?
        public let score: Int?
        public let formats: [String]
        public let filename: String?
        public init(quality: String?, size: Int64?, score: Int?, formats: [String], filename: String? = nil) {
            self.quality = quality
            self.size = size
            self.score = score
            self.formats = formats
            self.filename = filename
        }
    }

    public init(
        item: QueueItem,
        progressOverride: Double? = nil,
        showUpgradeDiff: Bool = true,
        showHeader: Bool = false,
        compactSpec: Bool = false,
        existingOverride: ExistingFileSnapshot? = nil
    ) {
        self.item = item
        self.progressOverride = progressOverride
        self.showUpgradeDiff = showUpgradeDiff
        self.showHeader = showHeader
        self.compactSpec = compactSpec
        self.existingOverride = existingOverride
    }

    private var progress: Double { progressOverride ?? item.progress }
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
        // With an explicit override we trust the caller to pass it
        // only for upgrade contexts; without one, gate on the
        // QueueItem's own upgrade flag + populated existing fields.
        if existingOverride != nil { return hasExistingMetadata }
        return item.isUpgrade && hasExistingMetadata
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status + spec row sits ABOVE the progress bar (per user
            // direction) so the row reads top-down: what/quality, then the
            // bar. The detail variant (`!compactSpec`) has no bar — its diff
            // grid is part of this header block.
            if showHeader {
                HStack(spacing: 6) {
                    // Queue rows (compactSpec) drop the bordered "pill" — the
                    // icon + coloured word are enough; the border read as a
                    // redundant label there.
                    StatusIconLabel(status: item.status, bordered: !compactSpec)
                    // Compact queue rows carry the badge on their title line
                    // (no room here next to status + client + spec); detail
                    // surfaces show it in this header.
                    if !compactSpec {
                        MediaBadgeCluster(isUpgrade: item.isUpgrade)
                    }
                    if let client = item.downloadClient {
                        DownloadClientLabel(name: client)
                    }
                    Spacer(minLength: 6)
                    // List variant always shows the inline spec —
                    // upgrade context lives in detail (one screen up).
                    if compactSpec {
                        inlineSpec
                    }
                }
                if !compactSpec {
                    // Detail variant — one row per dimension
                    // (Quality / Size / Score) in an aligned grid. For
                    // a real upgrade we also pass the OLD values +
                    // Formaty / Plik so the table renders the full diff
                    // (arrows, second version, deltas). For a plain
                    // "new" download we pass no OLD data and let the
                    // table degrade to a label+value spec — same grid,
                    // no arrows, no second version. Formats / filename
                    // stay nil in that case because the surrounding
                    // detail section renders its own CF-chip strip and
                    // release-name block for non-upgrades.
                    // Experiment: a real upgrade renders the extracted
                    // side-by-side `UpgradeDiffView` (current file → incoming,
                    // gained/lost format chips). Built from the `effective*`
                    // values so Sonarr's side-channel `existingOverride` is
                    // honoured. A plain "new" download (no OLD data) keeps the
                    // degraded `UpgradeDiffTable` spec grid.
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
                                tint: tint
                            )
                        }
                    }
                    // Nudge the facts grid down off the progress-bar
                    // block so it doesn't read as glued to the bar.
                    .padding(.top, 5)

                    // Where the grab came from — previously tooltip-only,
                    // which left both the movie and series details without
                    // the indexer.
                    if let indexer = item.indexer, !indexer.isEmpty {
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
            // Progress bar BELOW the status/spec row (compact / queue
            // variant only — detail surfaces show progress in their CTA).
            progressBarWithPercent
        }
    }

    @ViewBuilder
    private var progressBarWithPercent: some View {
        // Queue rows keep the full-width track bar, doubled to 6pt so it
        // reads as a deliberate progress bar rather than a hairline. The
        // detail drops it entirely — progress shows in the Resume/Pause CTA.
        if compactSpec {
            LiveProgress(item: item) { live in
                // `progressOverride` wins when the card speaks for a pack's
                // representative row rather than for `item` itself.
                ThinProgressBar(progress: progressOverride ?? live, tint: tint, height: 6)
            }
        }
    }

    /// Trailing-edge spec for the compact queue-row variant —
    /// `quality · size` condensed to fit next to the status pill /
    /// client label on a single row. The score moved up to the row's
    /// title line (rendered by the queue rows themselves).
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
