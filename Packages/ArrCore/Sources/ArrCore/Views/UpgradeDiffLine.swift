import SwiftUI

/// Detail-surface spec grid, one row per dimension as `OLD → NEW (+Δ)`.
/// List rows use the plain inline spec: no room for lateral comparisons.
struct UpgradeDiffTable: View {
    let newQuality: String?
    let newSize: Int64?
    let newScore: Int
    let oldQuality: String?
    let oldSize: Int64?
    let oldScore: Int?
    /// Rendered as one chip strip: kept neutral, added green, removed red.
    let newFormats: [String]
    let oldFormats: [String]
    /// Stacked rather than lateral: filenames are too long for an arrow row.
    let newFilename: String?
    let oldFilename: String?
    let indexer: String?
    let tint: Color

    init(
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
        indexer: String? = nil,
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
        self.indexer = indexer
        self.tint = tint
    }

    var body: some View {
        if hasAnyOld {
            diffBody
        } else {
            plainBody
        }
    }

    private var hasAnyOld: Bool {
        (oldQuality.map { !$0.isEmpty } ?? false)
            || (oldSize ?? 0) > 0
            || oldScore != nil
            || !oldFormats.isEmpty
            || (oldFilename.map { !$0.isEmpty } ?? false)
    }

    private var diffBody: some View {
        // A Grid keeps the arrow column aligned across rows.
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
                              sign: delta > 0 ? 1 : (delta < 0 ? -1 : 0))
                }
            }
            if newScore != 0 || oldScore != nil {
                let nScore = newScore
                let oScore = oldScore ?? 0
                let delta = nScore - oScore
                GridRow {
                    label("queue.score.button")
                    oldCell(oldScore != nil ? ScoreLabel.text(oScore) : nil)
                    arrowCell(showArrow: oldScore != nil && delta != 0)
                    newCell(ScoreLabel.text(nScore))
                    deltaCell(text: oldScore != nil && delta != 0 ? ScoreLabel.deltaText(delta) : nil,
                              sign: delta)
                }
            }
            if !newFormats.isEmpty || !oldFormats.isEmpty {
                GridRow {
                    label("common.customFormats.button")
                    formatChipsCell()
                        .gridCellColumns(4)
                }
            }
            if newFilename != nil || oldFilename != nil {
                GridRow {
                    label("queue.file.button")
                    filenamesCell()
                        .gridCellColumns(4)
                }
            }
            indexerRow(columns: 4)
        }
    }

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
                    // No delta column here, so the score keeps ScoreLabel's sign colour.
                    ScoreLabel(score: newScore, size: 11, weight: .semibold)
                        .gridColumnAlignment(.leading)
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
            indexerRow(columns: 1)
        }
    }

    /// `columns` spans the diff layout's OLD / arrow / NEW / delta cells.
    @ViewBuilder
    private func indexerRow(columns: Int) -> some View {
        if let indexer, !indexer.isEmpty {
            GridRow {
                label("Indexer")
                Text(indexer)
                    .scaledFont(size: 11)
                    .gridCellColumns(columns)
            }
        }
    }

    @ViewBuilder
    private func formatChipsCell() -> some View {
        let newSet = Set(newFormats)
        let oldSet = Set(oldFormats)
        let removed = oldFormats.filter { !newSet.contains($0) }
        TooltipFlowLayout(spacing: 4) {
            ForEach(newFormats, id: \.self) { f in
                let isAdded = !oldSet.contains(f)
                TagChip(text: f, color: isAdded ? .green : .primary)
            }
            ForEach(removed, id: \.self) { f in
                // "−" prefix so removals read without colour.
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

    /// The only coloured value in the table: tinting a side by its own sign would compete with the delta.
    /// `sign` is anything whose signum matches the change.
    @ViewBuilder
    private func deltaCell(text: String?, sign: Int) -> some View {
        if let text {
            Text(verbatim: "(\(text))")
                .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(ScoreLabel.deltaColor(sign))
                .lineLimit(1)
                .gridColumnAlignment(.leading)
        } else {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

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

}
