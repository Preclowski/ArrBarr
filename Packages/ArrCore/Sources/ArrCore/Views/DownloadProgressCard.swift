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
    /// `true` mutes the trailing edge fade on the status row when
    /// the row's hover overlay is going to paint its own gradient
    /// on top — avoids double-fade artefacts.
    let fadeTrailing: Bool
    /// Show the inline upgrade diff sub-line (`└─ OLD: quality · size (±delta)`).
    /// Defaults to true; surfaces that already render an explicit
    /// existing-file section can pass false.
    let showUpgradeDiff: Bool
    /// Render the status icon + label / percent / score header above
    /// the bar. Queue-row variants set `false` because the row
    /// already shows status info inline above the card.
    let showHeader: Bool
    /// Legacy flag — kept for source-compat with existing call sites
    /// but no longer affects rendering. The progress bar now always
    /// sits at the top of the card (with the percent rendered on
    /// top of it) per user direction.
    let showProgressFill: Bool
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
        public init(quality: String?, size: Int64?, score: Int?, formats: [String]) {
            self.quality = quality
            self.size = size
            self.score = score
            self.formats = formats
        }
    }

    public init(
        item: QueueItem,
        progressOverride: Double? = nil,
        fadeTrailing: Bool = false,
        showUpgradeDiff: Bool = true,
        showHeader: Bool = false,
        showProgressFill: Bool = true,
        compactSpec: Bool = false,
        existingOverride: ExistingFileSnapshot? = nil
    ) {
        self.item = item
        self.progressOverride = progressOverride
        self.fadeTrailing = fadeTrailing
        self.showUpgradeDiff = showUpgradeDiff
        self.showHeader = showHeader
        self.showProgressFill = showProgressFill
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
    private var willShowDiff: Bool {
        guard showUpgradeDiff else { return false }
        // With an explicit override we trust the caller to pass it
        // only for upgrade contexts; without one, gate on the
        // QueueItem's own upgrade flag + populated existing fields.
        if existingOverride != nil { return hasExistingMetadata }
        return item.isUpgrade && hasExistingMetadata
    }
    private var tagsDiffer: Bool {
        Set(item.customFormats) != Set(effectiveExistingFormats)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Progress bar always on top — `percent` centered as
            // overlay on the bar itself so the user reads "47%"
            // and the bar's fill simultaneously, no separate %
            // label hunting for space in the status row.
            progressBarWithPercent
            if showHeader {
                HStack(spacing: 6) {
                    StatusIconLabel(status: item.status)
                    if let client = item.downloadClient {
                        DownloadClientLabel(name: client)
                    }
                    Spacer(minLength: 6)
                    if compactSpec {
                        // Queue-row variant: spec inline on the
                        // trailing edge, score still left of size
                        // for left-to-right reading "quality · size
                        // · +score".
                        inlineSpec
                    }
                }
                if !compactSpec {
                    specLine(
                        quality: item.quality,
                        size: item.sizeTotal > 0 ? item.sizeTotal : nil,
                        score: item.customFormatScore,
                        isExisting: false
                    )
                }
            }
            if willShowDiff {
                ExistingFileDiffRow(
                    existingQuality: effectiveExistingQuality,
                    existingSize: effectiveExistingSize,
                    existingScore: effectiveExistingScore,
                    newScore: item.customFormatScore,
                    newQuality: item.quality,
                    newSize: item.sizeTotal > 0 ? item.sizeTotal : nil,
                    tagsDiffer: tagsDiffer
                )
            }
        }
    }

    @ViewBuilder
    private var progressBarWithPercent: some View {
        // No outer height padding — the bar's intrinsic 3pt is enough
        // now that the % overlay is gone. The 18pt frame existed so
        // the centred percent label had a vertical band to sit in;
        // without the label it was just a thick whitespace cushion
        // around a thin bar.
        ThinProgressBar(progress: progress, tint: tint)
    }

    /// Trailing-edge spec for the compact queue-row variant. Same
    /// content as `specLine` but condensed to fit next to the
    /// status pill / client label on a single row.
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
                    Text("·").foregroundStyle(.tertiary)
                }
                Text(ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file))
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
            if item.customFormatScore != 0 {
                Text("·").foregroundStyle(.tertiary)
                ScoreLabel(score: item.customFormatScore, size: 10)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// `quality · size · score` row used both for the NEW spec line
    /// in the card header and conceptually mirrored by
    /// `ExistingFileDiffRow` for the OLD line. `isExisting` controls
    /// the foreground weight — primary for the active download,
    /// secondary for the existing file (rendered separately by
    /// `ExistingFileDiffRow`; this helper is the NEW path only).
    @ViewBuilder
    private func specLine(quality: String?, size: Int64?, score: Int, isExisting: Bool) -> some View {
        HStack(spacing: 4) {
            if let q = quality, !q.isEmpty {
                Text(q)
                    .scaledFont(size: 11, weight: isExisting ? .regular : .medium)
                    .foregroundStyle(isExisting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            if let size, size > 0 {
                if quality?.isEmpty == false {
                    Text("·").foregroundStyle(.tertiary)
                }
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            if score != 0 {
                Text("·").foregroundStyle(.tertiary)
                ScoreLabel(score: score, size: 11)
            }
            Spacer(minLength: 0)
        }
    }

    private var hasExistingMetadata: Bool {
        (effectiveExistingQuality.map { !$0.isEmpty } ?? false)
            || (effectiveExistingSize ?? 0) > 0
            || (effectiveExistingScore ?? 0) != 0
    }
}
