import SwiftUI

public extension QueueItem.Status {
    var symbol: String {
        switch self {
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .queued: return "clock.fill"
        case .importing: return "tray.and.arrow.down.fill"
        case .completed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .paused: return .orange
        case .failed, .warning: return .red
        case .completed: return .green
        case .importing: return .purple
        default: return .blue
        }
    }
}

public struct QueueRowView: View {
    let item: QueueItem
    /// Action callbacks instead of an `@ObservedObject viewModel` so the row
    /// re-renders only when its own `item` value changes — not on every
    /// QueueViewModel publish. Closures are wrapped in `Equatable` checks at
    /// the SwiftUI diff level via the surrounding `ForEach(... id: \.id)`.
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    var onShowDetail: (() -> Void)? = nil
    @EnvironmentObject var configStore: ConfigStore
    /// Surfaces that have a permanent detail pane (the desktop window) set
    /// this to `true` so we skip the redundant long-hover tooltip. The
    /// menu-bar popover leaves it false.
    @Environment(\.suppressRowTooltip) private var suppressRowTooltip
    @State private var isHovering = false
    @State private var showDeleteConfirmation = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    private var canControl: Bool {
        switch item.downloadProtocol {
        case .usenet:
            return (configStore.sabnzbd.isConfigured && !configStore.sabnzbd.apiKey.isEmpty)
                || configStore.nzbget.isConfigured
        case .torrent:
            return configStore.qbittorrent.isConfigured
                || configStore.transmission.isConfigured
                || configStore.rtorrent.isConfigured
                || configStore.deluge.isConfigured
        case .unknown:
            return false
        }
    }

    private var canPauseResume: Bool {
        item.status == .downloading || item.status == .paused
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: item.source), cornerRadius: 4) {
                RemotePoster(
                    url: item.posterURL,
                    apiKey: item.posterRequiresAuth ? apiKeyForSource : nil,
                    size: posterSize,
                    cornerRadius: 4,
                    fallbackSymbol: item.source.symbol
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(item.isUpgrade ? "Upgrade" : "New")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(item.isUpgrade ? AnyShapeStyle(Color.indigo) : AnyShapeStyle(Color.accentColor))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                item.isUpgrade ? AnyShapeStyle(Color.indigo.opacity(0.15)) : AnyShapeStyle(Color.accentColor.opacity(0.15)),
                                in: Capsule()
                            )

                        if let client = item.downloadClient {
                            let color = downloadClientColor(client)
                            Text(client)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(color)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(color.opacity(0.15), in: Capsule())
                                .lineLimit(1)
                        }
                    }

                    if let sub = item.subtitle {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 3) {
                        Image(systemName: item.status.symbol)
                            .foregroundStyle(item.status.tint)
                            .font(.system(size: 8))
                        Text(LocalizedStringKey(item.status.displayName))
                            .foregroundStyle(item.status.tint)
                        if !metaLine.isEmpty {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(metaLine)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 10))
                    .lineLimit(1)
                }
                // Keep action buttons visible while the tooltip popover is
                // open: the popover floats above the row and steals the
                // mouse, dropping `isHovering` to false — without this the
                // pause/remove icons would vanish the moment the tooltip
                // appeared, even though the cursor is still on the row.
                // iOS has no hover, so on touch devices the action buttons
                // sit always-visible — there's no hover to gate them on.
                #if os(macOS)
                .hoverActions(visible: isHovering || showTooltip) { actionButtons }
                #else
                .hoverActions(visible: true) { actionButtons }
                #endif

                ThinProgressBar(progress: item.progress, tint: item.status.tint)

                if !item.customFormats.isEmpty || item.customFormatScore != 0 {
                    CustomFormatStrip(
                        formats: item.customFormats,
                        score: item.customFormatScore,
                        help: customFormatsTooltip
                    )
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onShowDetail?()
        }
        // Hover-only affordances live on macOS. On iOS the same information
        // is available by tapping into the detail view, and the floating
        // tooltip popover would render as a sheet — wrong UX for a brief
        // glance. So both the hover-state row tint and the long-hover
        // tooltip are macOS-only.
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            // Only schedule the long-hover tooltip when the host surface
            // doesn't already have a permanent detail pane.
            hoverTask?.cancel()
            if hovering && !suppressRowTooltip {
                hoverTask = Task { @MainActor [self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if !Task.isCancelled && self.isHovering { showTooltip = true }
                }
            } else {
                showTooltip = false
            }
        }
        .popover(isPresented: $showTooltip, arrowEdge: .trailing) {
            QueueItemTooltip(
                item: item,
                apiKey: item.posterRequiresAuth ? apiKeyForSource : nil,
                locale: configStore.currentLocale
            )
            // Default .transient eats the first click outside the popover.
            // .applicationDefined makes the popover passive — we close it
            // ourselves in onHover when the cursor leaves the row.
            .popoverBehavior(.applicationDefined)
        }
        #endif
        .alert("Remove download?", isPresented: $showDeleteConfirmation) {
            Button("Remove", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(item.title)\" from the download client.")
        }
    }

    // MARK: - Poster helpers

    private var posterSize: CGSize {
        switch item.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 40, height: 60)
        case .lidarr: return CGSize(width: 40, height: 40)
        }
    }

    private var apiKeyForSource: String? {
        configStore.serviceConfig(for: item.source).apiKey
    }

    // MARK: - Actions

    private var actionButtons: some View {
        // Single glass capsule wrapping the whole action cluster — the
        // cluster is the affordance, not the individual buttons. Red lives
        // only in the trash glyph; the capsule stays neutral so it doesn't
        // scream "destructive" at the user just because remove is one
        // option in there. Matches the chat input bar's chrome (see
        // `glassyFloatingBar`).
        HStack(spacing: 4) {
            if canControl && canPauseResume {
                if item.isPaused {
                    IconButton(symbol: "play.fill", helpKey: "Resume", accessibilityLabel: "Resume \(item.title)") {
                        onResume()
                    }
                } else {
                    IconButton(symbol: "pause.fill", helpKey: "Pause", accessibilityLabel: "Pause \(item.title)") {
                        onPause()
                    }
                }
            }
            if canControl {
                IconButton(symbol: "trash", helpKey: "Remove from client",
                           accessibilityLabel: "Remove \(item.title)",
                           tint: .red) {
                    showDeleteConfirmation = true
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassPill()
    }

    // MARK: - Custom format tags

    private var customFormatsTooltip: String {
        var parts = item.customFormats.map { "[\($0)]" }
        if item.customFormatScore != 0 {
            let sign = item.customFormatScore > 0 ? "+" : ""
            parts.append("\(sign)\(item.customFormatScore)")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Display helpers

    private var metaLine: String {
        var parts: [String] = []
        if let q = item.quality, !q.isEmpty { parts.append(q) }
        if let t = formattedTimeLeft, !t.isEmpty, t != "00:00:00" { parts.append(t) }
        let sizeStr = ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file)
        parts.append(sizeStr)
        return parts.joined(separator: " · ")
    }

    private var formattedTimeLeft: String? {
        guard let raw = item.timeLeft, !raw.isEmpty else { return nil }
        // Arr APIs sometimes return "HH:mm:ss.fffffff" — trim sub-second precision.
        return String(raw.prefix { $0 != "." })
    }

}


// MARK: - Rich tooltip

public struct QueueItemTooltip: View {
    let item: QueueItem
    var apiKey: String? = nil
    var locale: Locale = Locale(identifier: "en")
    @EnvironmentObject var configStore: ConfigStore

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: item.source), cornerRadius: 6) {
                RemotePoster(
                    url: item.posterURL,
                    apiKey: apiKey,
                    size: posterSize,
                    cornerRadius: 6,
                    fallbackSymbol: item.source.symbol
                )
            }
            tooltipContent
        }
        .padding(12)
        .frame(width: 480)
        .background(.regularMaterial)
    }

    private var posterSize: CGSize {
        switch item.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 110, height: 165)
        case .lidarr: return CGSize(width: 110, height: 110)
        }
    }

    private var tooltipContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider().opacity(0.5)
            infoGrid

            if !item.customFormats.isEmpty || item.customFormatScore != 0 {
                customFormatChipStrip(
                    tags: item.customFormats,
                    score: item.customFormatScore != 0 ? item.customFormatScore : nil
                )
            }

            if item.isUpgrade,
               item.existingCustomFormatScore != nil
                || item.existingQuality != nil
                || !item.existingCustomFormats.isEmpty {
                upgradeDivider
                Text("Existing file", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                existingInfo
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if let client = item.downloadClient {
                        let color = downloadClientColor(client)
                        Text(client)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.15), in: Capsule())
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            if let sub = item.subtitle {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var infoGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            if let q = item.quality, !q.isEmpty {
                row("Quality", value: "\(q) · \(sizeString)")
            } else {
                row("Size", value: sizeString)
            }
            if let indexer = item.indexer, !indexer.isEmpty {
                row("Indexer", value: indexer)
            }
            if let file = item.releaseName, !file.isEmpty {
                row("File", value: file, mono: true, wraps: true)
            }
        }
    }

    private var upgradeDivider: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
            Text("Upgrade", bundle: .module)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.indigo)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.indigo.opacity(0.15), in: Capsule())
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        .padding(.top, 4)
    }

@ViewBuilder
    private var existingInfo: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            if let q = item.existingQuality, !q.isEmpty {
                if let size = item.existingSize, size > 0 {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                    row("Quality", value: "\(q) · \(sizeStr)")
                } else {
                    row("Quality", value: q)
                }
            } else if let size = item.existingSize, size > 0 {
                row("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
        }
        customFormatChipStrip(
            tags: item.existingCustomFormats,
            score: item.existingCustomFormatScore
        )
    }

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, valueColor: Color? = nil, mono: Bool = false, wraps: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundStyle(valueColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .lineLimit(wraps ? nil : 2)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

func downloadClientColor(_ name: String) -> Color {
    let n = name.lowercased()
    if n.contains("sab") { return .orange }
    if n.contains("nzbget") { return .green }
    if n.contains("qbit") { return .blue }
    if n.contains("transmission") { return .red }
    if n.contains("rtorrent") || n.contains("rutorrent") { return .teal }
    if n.contains("deluge") { return .purple }
    return .gray
}

/// Custom-format chips plus an optional score chip, wrapping with
/// `TooltipFlowLayout`. Pulled out of `QueueRowView` / `QueueGroupRowView`
/// since both tooltips rendered byte-identical strips inline.
@ViewBuilder
public func customFormatChipStrip(tags: [String], score: Int?) -> some View {
    if !tags.isEmpty || (score ?? 0) != 0 {
        TooltipFlowLayout(spacing: 3) {
            ForEach(tags, id: \.self) { TagChip(text: $0) }
            if let score, score != 0 {
                let sign = score > 0 ? "+" : ""
                TagChip(text: "\(sign)\(score)", color: score > 0 ? .green : .red)
            }
        }
        .padding(.top, 2)
    }
}

public struct TagChip: View {
    let text: String
    var color: Color = .primary

    public var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color == .primary ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            // `.quaternary` is a hierarchical material — inside a popover
            // (which is itself a `.regularMaterial` container) it resolves
            // to a much darker tone, so chips look like solid black pills.
            // Explicit colour-with-opacity renders the same in both
            // contexts.
            .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

public struct TooltipFlowLayout: Layout {
    var spacing: CGFloat = 4

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(rows.count - 1) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [(indices: [Int], height: CGFloat)] {
        var rows: [(indices: [Int], height: CGFloat)] = []
        var current: (indices: [Int], height: CGFloat) = ([], 0)
        var x: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !current.indices.isEmpty && x + size.width > maxWidth {
                rows.append(current)
                current = ([], 0)
                x = 0
            }
            current.indices.append(i)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Overlays hover-only `actions` on the top-trailing edge of a content
/// block, with a short gradient fade behind the buttons so any tags / chips
/// they overlap fade out cleanly. The content keeps its full width
/// regardless of hover state — actions don't push the layout sideways
/// (which is what was wrapping title-row badges to a second line).
public struct HoverActionOverlay<Actions: View>: ViewModifier {
    let visible: Bool
    @ViewBuilder let actions: () -> Actions

    public func body(content: Content) -> some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            if visible {
                actions()
                    .padding(.leading, 8)
                    .background(
                        LinearGradient(
                            colors: [
                                Color.platformWindowBackground.opacity(0),
                                Color.platformWindowBackground.opacity(0.95),
                                Color.platformWindowBackground.opacity(0.95),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .transition(.opacity)
            }
        }
    }
}

public extension View {
    func hoverActions<Actions: View>(
        visible: Bool,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        modifier(HoverActionOverlay(visible: visible, actions: actions))
    }
}

public struct IconButton: View {
    @EnvironmentObject var configStore: ConfigStore
    let symbol: String
    let helpKey: String
    var accessibilityLabel: String = ""
    /// Color used for the symbol on hover. nil → primary (neutral).
    /// Destructive actions pass `.red` so the trash glows red when the user
    /// is about to remove something.
    var tint: Color? = nil
    let action: () -> Void

    @State private var isHovering = false

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovering ? (tint ?? .primary) : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        #endif
        .help(Text(LocalizedStringKey(helpKey), bundle: .module))
        .accessibilityLabel(
            accessibilityLabel.isEmpty
                ? Text(LocalizedStringKey(helpKey), bundle: .module)
                : Text(verbatim: accessibilityLabel)
        )
    }
}

// MARK: - Shared row chrome
//
// SwiftUI's linear `ProgressView` silently ignores `.frame(height: 3)`,
// which is what made the Sonarr group rows render visibly thicker than
// Radarr/Lidarr rows even though both wrote the same modifier. Every
// progress bar in the app — listing rows, group rows, season tooltips,
// detail panels — now goes through `ThinProgressBar` so thickness stays
// pixel-identical regardless of context.
public struct ThinProgressBar: View {
    let progress: Double
    let tint: Color
    var height: CGFloat = 3
    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.primary.opacity(0.10))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(tint)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: height)
    }
}

/// The single-line custom-format chip strip with a fade-out gradient when
/// the chips overflow the available width. Used by listing rows so the
/// row never wraps; detail views use the wrapping `CustomFormatChips`
/// variant instead.
public struct CustomFormatStrip: View {
    let formats: [String]
    let score: Int
    var help: String? = nil

    public var body: some View {
        let view = Color.clear
            .frame(height: 14)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                HStack(spacing: 4) {
                    ForEach(formats, id: \.self) { cf in
                        Text(cf)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    if score != 0 {
                        let sign = score > 0 ? "+" : ""
                        Text("\(sign)\(score)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(score > 0 ? Color.green : Color.red)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                .fixedSize()
            }
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

        if let help {
            view.help(Text(verbatim: help))
        } else {
            view
        }
    }
}
