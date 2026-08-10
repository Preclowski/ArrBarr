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

    /// Ways to build a side out of the *library* payloads (as opposed to the
    /// queue's `existing*` fields above) — what manual search compares its
    /// candidates against. Mirrors `ExistingFileBanner`'s two file inits so the
    /// banner and the diff can't disagree about what's on disk.
    static func side(file: ArrFile) -> Side {
        Side(quality: file.quality?.name,
             score: file.customFormatScore,
             size: file.size,
             formats: (file.customFormats ?? []).map(\.name),
             filename: file.relativePath)
    }

    /// Sonarr's `episodefile` payload — same fields as `ArrFile` plus an id.
    static func side(episodeFile: SonarrEpisodeFile) -> Side {
        Side(quality: episodeFile.quality?.name,
             score: episodeFile.customFormatScore,
             size: episodeFile.size,
             formats: (episodeFile.customFormats ?? []).map(\.name),
             filename: episodeFile.relativePath)
    }

    /// A manual-search candidate as the *incoming* side.
    static func side(release: Release) -> Side {
        Side(quality: release.qualityName,
             score: release.customFormatScore,
             size: release.sizeBytes > 0 ? release.sizeBytes : nil,
             formats: (release.customFormats ?? []).compactMap(\.name),
             filename: release.title)
    }

    private var gained: [String] { Set(incoming.formats).subtracting(current.formats).sorted() }
    private var lost: [String] { Set(current.formats).subtracting(incoming.formats).sorted() }
    /// Formats both files carry. Shown plain (no sign, `.primary`) so the
    /// strip describes the whole incoming file rather than only its edits —
    /// "what am I getting" is as much a part of the comparison as "what
    /// changed", and a chip list that silently omitted the unchanged ones
    /// read as a much thinner file than it is.
    private var unchanged: [String] { Set(incoming.formats).intersection(current.formats).sorted() }


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
                column(side: current)
                Image(systemName: "arrow.right")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                column(side: incoming)
            }
            if !gained.isEmpty || !lost.isEmpty || !unchanged.isEmpty {
                // Wrap inline with the shared flow layout + diff-coloured
                // TagChips: green = gained, red = lost, plain = carried over
                // by both files. Same colour language as every other
                // custom-format diff in the app.
                TooltipFlowLayout(spacing: 3) {
                    ForEach(gained, id: \.self) { TagChip(text: "+\($0)", color: .green) }
                    ForEach(lost, id: \.self) { TagChip(text: "−\($0)", color: .red) }
                    ForEach(unchanged, id: \.self) { TagChip(text: $0, color: .primary) }
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
        // Custom formats follow the peek too: show only the displayed side's
        // formats (NEW by default, CURRENT while held) instead of stacking
        // gained + lost at once.
        let sideFormats = (comparing ? current.formats : incoming.formats).sorted()
        let otherFormats = Set(comparing ? incoming.formats : current.formats)
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
            column(side: side)
            // Formats for the shown side only — NEW lists the incoming file's
            // formats (gains, absent from the old file, in green +); CURRENT
            // (while held) lists the old file's (losses, absent from the new
            // file, in red −). Unchanged formats stay plain. The strip flips
            // with the peek instead of showing old + new simultaneously.
            if !sideFormats.isEmpty {
                TooltipFlowLayout(spacing: 3) {
                    ForEach(sideFormats, id: \.self) { f in
                        let changed = !otherFormats.contains(f)
                        TagChip(
                            text: changed ? (comparing ? "−\(f)" : "+\(f)") : f,
                            color: changed ? (comparing ? .red : .green) : .primary
                        )
                    }
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

    private func column(side: Side) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(side.quality ?? "—")
                .scaledFont(size: 12, weight: .semibold)
            if let score = side.score {
                // Deliberately uncoloured. Tinting a side by its own sign, or
                // by which side "won", put a third meaning on green inside a
                // view whose whole job is to show a change — the delta by the
                // arrow is the one number allowed to be coloured here.
                Text(verbatim: ScoreLabel.text(score))
                    .scaledFont(size: 10, monospacedDigit: true)
                    .foregroundStyle(.secondary)
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
