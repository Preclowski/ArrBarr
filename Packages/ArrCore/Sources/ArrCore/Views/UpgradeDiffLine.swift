import SwiftUI

/// Detail-surface upgrade diff — one row per dimension (Quality / Size /
/// Score) with values shown laterally as `OLD → NEW (+Δ)`. Used inside
/// DetailView's download section so the arrows stack into a vertical
/// column the eye can scan, and each row fits on a single line.
///
/// The list surface uses the plain inline spec (no diff) because list
/// rows don't have horizontal room for three lateral comparisons.
public struct UpgradeDiffTable: View {
    let newQuality: String?
    let newSize: Int64?
    let newScore: Int
    let oldQuality: String?
    let oldSize: Int64?
    let oldScore: Int?
    /// Custom format tag sets — render below the spec rows as a single
    /// unified chip strip (kept neutral, added green, removed red).
    /// Empty lists hide the row entirely.
    let newFormats: [String]
    let oldFormats: [String]
    /// Release / on-disk filenames — render as a "Plik" row with both
    /// values stacked (filenames are too long for a lateral arrow).
    /// nil hides the row.
    let newFilename: String?
    let oldFilename: String?
    let tint: Color

    public init(
        newQuality: String?,
        newSize: Int64?,
        newScore: Int,
        oldQuality: String?,
        oldSize: Int64?,
        oldScore: Int?,
        newFormats: [String] = [],
        oldFormats: [String] = [],
        newFilename: String? = nil,
        oldFilename: String? = nil,
        tint: Color = .accentColor
    ) {
        self.newQuality = newQuality
        self.newSize = newSize
        self.newScore = newScore
        self.oldQuality = oldQuality
        self.oldSize = oldSize
        self.oldScore = oldScore
        self.newFormats = newFormats
        self.oldFormats = oldFormats
        self.newFilename = newFilename
        self.oldFilename = oldFilename
        self.tint = tint
    }

    public var body: some View {
        // No old metadata to compare against (a fresh "new" download,
        // not an upgrade) → render the same labelled grid but as a
        // plain spec: labels + values only, no OLD column, no arrows,
        // no deltas. The user still reads Jakość / Rozmiar / Score in
        // the aligned grid they expect from the upgrade surface.
        if hasAnyOld {
            diffBody
        } else {
            plainBody
        }
    }

    /// Whether any "old" value is present — gates the diff vs plain
    /// layout. A pure-new download has none of these populated.
    private var hasAnyOld: Bool {
        (oldQuality.map { !$0.isEmpty } ?? false)
            || (oldSize ?? 0) > 0
            || oldScore != nil
            || !oldFormats.isEmpty
            || (oldFilename.map { !$0.isEmpty } ?? false)
    }

    private var diffBody: some View {
        // Grid keeps the `→` arrow column aligned across rows — easier
        // to scan than three independent HStacks where each row's
        // arrow lands at a different X.
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
            if let nq = newQuality, !nq.isEmpty {
                GridRow {
                    label("queue.quality.button")
                    oldCell(oldQuality)
                    arrowCell(showArrow: hasQualityChange)
                    newCell(nq)
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            if let ns = newSize, ns > 0 {
                let os = oldSize ?? 0
                let delta = ns - os
                GridRow {
                    label("queue.size.button")
                    oldCell(os > 0 ? formatBytes(os) : nil)
                    arrowCell(showArrow: os > 0 && delta != 0)
                    newCell(formatBytes(ns))
                    deltaCell(text: os > 0 && delta != 0 ? formatBytesDelta(delta) : nil,
                              isPositive: delta > 0)
                }
            }
            if newScore != 0 || oldScore != nil {
                let nScore = newScore
                let oScore = oldScore ?? 0
                let delta = nScore - oScore
                GridRow {
                    label("queue.score.button")
                    // Dedicated score cells: a negative score reads red on
                    // either side (matching the tooltip diff + queue list),
                    // not the neutral grey/primary every other value uses.
                    oldScoreCell(oldScore != nil ? oScore : nil)
                    arrowCell(showArrow: oldScore != nil && delta != 0)
                    newScoreCell(nScore)
                    deltaCell(text: oldScore != nil && delta != 0 ? "\(delta > 0 ? "+" : "")\(delta)" : nil,
                              isPositive: delta > 0)
                }
            }
            // Formaty — single chip strip showing the union of old +
            // new tags. Kept tags neutral, added green, removed red so
            // the user reads the full diff in one strip instead of two
            // chip rows.
            if !newFormats.isEmpty || !oldFormats.isEmpty {
                GridRow {
                    label("common.customFormats.button")
                    formatChipsCell()
                        .gridCellColumns(4)
                }
            }
            // Plik — NEW filename above, OLD below dimmed. Stacked,
            // not lateral, because release names are too long for
            // side-by-side reading on a popover-width surface.
            if newFilename != nil || oldFilename != nil {
                GridRow {
                    label("queue.file.button")
                    filenamesCell()
                        .gridCellColumns(4)
                }
            }
        }
    }

    /// Plain spec layout for non-upgrade downloads — two columns
    /// (label + value), no OLD cell / arrow / delta. Same labels and
    /// row ordering as the diff so the surface reads consistently
    /// whether or not there's something to compare against.
    private var plainBody: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
            if let nq = newQuality, !nq.isEmpty {
                GridRow {
                    label("queue.quality.button")
                    newCell(nq)
                }
            }
            if let ns = newSize, ns > 0 {
                GridRow {
                    label("queue.size.button")
                    newCell(formatBytes(ns))
                }
            }
            if newScore != 0 {
                GridRow {
                    label("queue.score.button")
                    newScoreCell(newScore)
                }
            }
            if !newFormats.isEmpty {
                GridRow {
                    label("common.customFormats.button")
                    TooltipFlowLayout(spacing: 4) {
                        ForEach(newFormats, id: \.self) { f in
                            TagChip(text: f, color: .primary)
                        }
                    }
                }
            }
            if let nf = newFilename, !nf.isEmpty {
                GridRow {
                    label("queue.file.button")
                    Text(nf)
                        .scaledFont(size: 11, design: .monospaced)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private func formatChipsCell() -> some View {
        let newSet = Set(newFormats)
        let oldSet = Set(oldFormats)
        // Order: NEW formats in their incoming order first (so the
        // user reads what they're GETTING), then any OLD-only ones
        // pinned at the end as removals.
        let removed = oldFormats.filter { !newSet.contains($0) }
        TooltipFlowLayout(spacing: 4) {
            ForEach(newFormats, id: \.self) { f in
                let isAdded = !oldSet.contains(f)
                TagChip(text: f, color: isAdded ? .green : .primary)
            }
            ForEach(removed, id: \.self) { f in
                // Removed chips get an explicit "−" prefix so the
                // user reads them as removals even without colour
                // context (colour-blind mode, low contrast).
                TagChip(text: "− \(f)", color: .red)
            }
        }
    }

    @ViewBuilder
    private func filenamesCell() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let nf = newFilename, !nf.isEmpty {
                Text(nf)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if let of = oldFilename, !of.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(of)
                        .scaledFont(size: 11, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    // Arrow sits at the trailing edge of the OLD line
                    // and points up to the NEW line above. Tail at
                    // bottom-right, head pointing up-left — reads as
                    // "this OLD got upgraded to the NEW above".
                    Image(systemName: "arrow.up.left")
                        .scaledFont(size: 9, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var hasQualityChange: Bool {
        guard let oq = oldQuality, !oq.isEmpty, let nq = newQuality else { return false }
        return oq != nq
    }

    @ViewBuilder
    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private func oldCell(_ text: String?) -> some View {
        if let text {
            Text(text)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .gridColumnAlignment(.leading)
        } else {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        }
    }

    @ViewBuilder
    private func arrowCell(showArrow: Bool) -> some View {
        if showArrow {
            Image(systemName: "arrow.right")
                .scaledFont(size: 9, weight: .bold)
                .foregroundStyle(tint)
                .gridColumnAlignment(.leading)
        } else {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        }
    }

    @ViewBuilder
    private func newCell(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: .semibold)
            .lineLimit(1)
            .gridColumnAlignment(.leading)
    }

    /// Old/original-file score — like `oldCell` but a negative score reads red
    /// (positive / zero stay secondary like every other old value).
    @ViewBuilder
    private func oldScoreCell(_ score: Int?) -> some View {
        if let score {
            Text(formatScore(score))
                .scaledFont(size: 11)
                .foregroundStyle(score < 0 ? Color.red : Color.secondary)
                .lineLimit(1)
                .gridColumnAlignment(.leading)
        } else {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        }
    }

    /// Incoming-file score — like `newCell` but a negative score reads red
    /// (positive / zero keep the semibold primary treatment).
    @ViewBuilder
    private func newScoreCell(_ score: Int) -> some View {
        Text(formatScore(score))
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(score < 0 ? Color.red : Color.primary)
            .lineLimit(1)
            .gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private func deltaCell(text: String?, isPositive: Bool) -> some View {
        if let text {
            Text(verbatim: "(\(text))")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(isPositive ? .green : .red)
                .lineLimit(1)
                .gridColumnAlignment(.leading)
        } else {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        }
    }

    /// "66,29 GB" — full precision for absolute values where the
    /// number itself matters.
    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "+39 GB" / "-1,2 GB" — compact delta for the (+Δ) column.
    private func formatBytesDelta(_ bytes: Int64) -> String {
        let sign = bytes >= 0 ? "+" : "−"
        let abs = Swift.abs(bytes)
        let gb = Double(abs) / 1_073_741_824
        let mb = Double(abs) / 1_048_576
        if gb >= 1 {
            return gb >= 10
                ? "\(sign)\(Int(gb.rounded())) GB"
                : "\(sign)\(String(format: "%.1f", gb)) GB"
        }
        return "\(sign)\(Int(mb.rounded())) MB"
    }

    /// "+4656" / "-120" — signed integer, matches ScoreLabel format
    /// without needing the chip chrome.
    private func formatScore(_ score: Int) -> String {
        score >= 0 ? "+\(score)" : "\(score)"
    }
}
