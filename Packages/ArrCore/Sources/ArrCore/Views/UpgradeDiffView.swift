import SwiftUI
import MediaKit

/// Side-by-side "current file → incoming release" comparison with gained and lost custom formats.
struct UpgradeDiffView: View {
    struct Side {
        let quality: String?
        let score: Int?
        let size: Int64?
        let formats: [String]
        var filename: String? = nil
    }

    let current: Side
    let incoming: Side
    let showFilenames: Bool
    let labeled: Bool

    init(current: Side, incoming: Side, showFilenames: Bool = false, labeled: Bool = false) {
        self.current = current
        self.incoming = incoming
        self.showFilenames = showFilenames
        self.labeled = labeled
    }

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
        self.labeled = false
    }

    /// Library payloads as sides, for manual search. Mirrors `ExistingFileBanner.init(file:)`
    /// so the banner and the diff agree about what's on disk.
    static func side(file: ArrFile) -> Side {
        Side(quality: file.quality?.name,
             score: file.customFormatScore,
             size: file.size,
             formats: (file.customFormats ?? []).map(\.name),
             filename: file.relativePath ?? file.path.map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    static func side(release: ArrRelease) -> Side {
        Side(quality: release.qualityName,
             score: release.customFormatScore,
             size: release.sizeBytes > 0 ? release.sizeBytes : nil,
             formats: (release.customFormats ?? []).compactMap(\.name),
             filename: release.title)
    }

    private var gained: [String] { Set(incoming.formats).subtracting(current.formats).sorted() }
    private var lost: [String] { Set(current.formats).subtracting(incoming.formats).sorted() }
    /// Shown plain so the strip describes the whole incoming file, not only its edits.
    private var unchanged: [String] { Set(incoming.formats).intersection(current.formats).sorted() }


    var body: some View {
        #if os(iOS)
        iosPeekBody
        #else
        sideBySideBody
        #endif
    }

    private var sideBySideBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                column(side: current, title: labeled ? Text("queue.currentFile.button", bundle: .module) : nil)
                Image(systemName: "arrow.right")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .padding(.top, labeled ? 15 : 1)
                column(side: incoming, title: labeled ? Text("queue.newFile.button", bundle: .module) : nil)
            }
            if !gained.isEmpty || !lost.isEmpty || !unchanged.isEmpty {
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
    @GestureState private var comparing = false

    /// iOS: the new file only; press and hold to peek at the current one.
    private var iosPeekBody: some View {
        let side = comparing ? current : incoming
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
        // minimumDistance 0 fires on touch-down; `updating` resets on release.
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($comparing) { _, state, _ in state = true }
        )
    }
    #endif

    /// Untruncated: the long original name is the point of showing it.
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

    private func column(side: Side, title: Text? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title {
                title
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.primary)
            }
            Text(side.quality ?? "—")
                .scaledFont(size: 12, weight: title == nil ? .semibold : .regular)
            if let score = side.score {
                // Uncoloured: the delta by the arrow is the only number allowed a colour here.
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
