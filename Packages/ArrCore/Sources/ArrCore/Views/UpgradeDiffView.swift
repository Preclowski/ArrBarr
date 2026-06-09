import SwiftUI

/// Side-by-side "current file → incoming release" upgrade comparison:
/// quality, custom-format score and size per side, plus the gained (green)
/// and lost (red) custom formats wrapped below. Extracted from the chat
/// queue card so the tooltip and detail surfaces can show the same diff.
struct UpgradeDiffView: View {
    struct Side {
        let quality: String?
        let score: Int?
        let size: Int64?
        let formats: [String]
        /// Release / on-disk file name. Rendered (untruncated) only when
        /// the view is asked to `showFilenames`.
        var filename: String? = nil
    }

    let current: Side
    let incoming: Side
    /// Detail and tooltip surfaces (wide) show the full file names; the
    /// narrow chat card leaves them off to stay compact.
    let showFilenames: Bool

    init(current: Side, incoming: Side, showFilenames: Bool = false) {
        self.current = current
        self.incoming = incoming
        self.showFilenames = showFilenames
    }

    /// Build from a queue row's `existing*` (current on-disk file) and
    /// release fields (the incoming download).
    init(item: QueueItem, showFilenames: Bool = false) {
        self.current = Side(
            quality: item.existingQuality,
            score: item.existingCustomFormatScore,
            size: item.existingSize,
            formats: item.existingCustomFormats,
            filename: item.existingFileName
        )
        self.incoming = Side(
            quality: item.quality,
            score: item.customFormatScore,
            size: item.sizeTotal,
            formats: item.customFormats,
            filename: item.releaseName
        )
        self.showFilenames = showFilenames
    }

    private var gained: [String] { Set(incoming.formats).subtracting(current.formats).sorted() }
    private var lost: [String] { Set(current.formats).subtracting(incoming.formats).sorted() }
    private var scoreImproved: Bool { (current.score ?? Int.min) < (incoming.score ?? Int.min) }

    var body: some View {
        #if os(iOS)
        iosPeekBody
        #else
        sideBySideBody
        #endif
    }

    /// macOS / wide surfaces: current → incoming side by side.
    private var sideBySideBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                column(side: current, scoreHighlighted: false)
                Image(systemName: "arrow.right")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                column(side: incoming, scoreHighlighted: scoreImproved)
            }
            if !gained.isEmpty || !lost.isEmpty {
                // Wrap inline with the shared flow layout + diff-coloured
                // TagChips (green = gained, red = lost) — the same colour
                // language used for custom-format diffs elsewhere.
                TooltipFlowLayout(spacing: 3) {
                    ForEach(gained, id: \.self) { TagChip(text: "+\($0)", color: .green) }
                    ForEach(lost, id: \.self) { TagChip(text: "−\($0)", color: .red) }
                }
            }
            if showFilenames {
                filenames
            }
        }
    }

    #if os(iOS)
    /// True while a finger is held down — peeks at the current (old) file.
    @GestureState private var comparing = false

    /// iOS: show only the NEW file by default; press-and-hold to peek the
    /// current one. Saves the cramped two-column layout on a narrow screen
    /// and turns the comparison into a deliberate gesture.
    private var iosPeekBody: some View {
        let side = comparing ? current : incoming
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                (comparing
                    ? Text("queue.currentFile.button", bundle: .module)
                    : Text("queue.newFile.button", bundle: .module))
                    .scaledFont(size: 9, weight: .semibold)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(comparing ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                Spacer(minLength: 0)
            }
            column(side: side, scoreHighlighted: !comparing && scoreImproved)
            if !gained.isEmpty || !lost.isEmpty {
                TooltipFlowLayout(spacing: 3) {
                    ForEach(gained, id: \.self) { TagChip(text: "+\($0)", color: .green) }
                    ForEach(lost, id: \.self) { TagChip(text: "−\($0)", color: .red) }
                }
            }
            if showFilenames, let name = side.filename, !name.isEmpty {
                Text(name)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(comparing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Image(systemName: "hand.tap.fill").scaledFont(size: 9)
                Text("queue.holdToCompare.button", bundle: .module).scaledFont(size: 10)
            }
            .foregroundStyle(.tertiary)
            .opacity(comparing ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: comparing)
        // minimumDistance 0 → fires on touch-down; `updating` resets to false
        // on release, so the old file shows only while held.
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($comparing) { _, state, _ in state = true }
        )
    }
    #endif

    /// Incoming release name on top, the file it replaces as a `└─` sub-line.
    /// Rendered untruncated (wraps instead of clipping) — the long original
    /// name is the whole point of showing it.
    @ViewBuilder
    private var filenames: some View {
        let incomingName = incoming.filename
        let currentName = current.filename
        if (incomingName?.isEmpty == false) || (currentName?.isEmpty == false) {
            VStack(alignment: .leading, spacing: 3) {
                if let name = incomingName, !name.isEmpty {
                    Text(name)
                        .scaledFont(size: 11, design: .monospaced)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let name = currentName, !name.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: "⇱")
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(.tertiary)
                        Text(name)
                            .scaledFont(size: 11, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func column(side: Side, scoreHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(side.quality ?? "—")
                .scaledFont(size: 12, weight: .semibold)
            if let score = side.score {
                // Render the integer verbatim — interpolating it straight into
                // a localized string applies the locale's grouping separator
                // ("1 250"), which reads as a glitch on a raw score.
                Text(verbatim: String(localized: "queue.score.button", bundle: .module) + " \(score)")
                    .scaledFont(size: 10)
                    .foregroundStyle(scoreHighlighted ? .green : .secondary)
            }
            if let size = side.size, size > 0 {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
