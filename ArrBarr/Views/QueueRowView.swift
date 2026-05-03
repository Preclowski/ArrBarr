import SwiftUI

extension QueueItem.Status {
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

struct QueueRowView: View {
    let item: QueueItem
    /// Action callbacks instead of an `@ObservedObject viewModel` so the row
    /// re-renders only when its own `item` value changes — not on every
    /// QueueViewModel publish. Closures are wrapped in `Equatable` checks at
    /// the SwiftUI diff level via the surrounding `ForEach(... id: \.id)`.
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var configStore: ConfigStore
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemotePoster(
                url: item.posterURL,
                apiKey: item.posterRequiresAuth ? apiKeyForSource : nil,
                size: posterSize,
                cornerRadius: 4,
                fallbackSymbol: fallbackSymbol
            )

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
                .hoverActions(visible: isHovering || showTooltip) { actionButtons }

                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(item.status.tint)
                    .frame(height: 3)

                if !item.customFormats.isEmpty {
                    customFormatTags
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            hoverTask?.cancel()
            if hovering {
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
        }
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
        case .radarr, .sonarr: return CGSize(width: 40, height: 60)
        case .lidarr: return CGSize(width: 40, height: 40)
        }
    }

    private var fallbackSymbol: String {
        switch item.source {
        case .radarr: return "film"
        case .sonarr: return "tv"
        case .lidarr: return "music.note"
        }
    }

    private var apiKeyForSource: String? {
        switch item.source {
        case .radarr: return configStore.radarr.apiKey
        case .sonarr: return configStore.sonarr.apiKey
        case .lidarr: return configStore.lidarr.apiKey
        }
    }

    // MARK: - Actions

    private var webURL: URL? {
        guard let slug = item.contentSlug else { return nil }
        let (cfg, path): (ServiceConfig, String) = switch item.source {
        case .radarr: (configStore.radarr, "/movie/\(slug)")
        case .sonarr: (configStore.sonarr, "/series/\(slug)")
        case .lidarr: (configStore.lidarr, "/album/\(slug)")
        }
        return URL(string: cfg.baseURL)?.appendingPathComponent(path)
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            if let url = webURL {
                IconButton(symbol: "safari", helpKey: "Open in browser", accessibilityLabel: "Open \(item.title) in browser") {
                    NSWorkspace.shared.open(url)
                }
            }
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
                IconButton(symbol: "trash", helpKey: "Remove from client", accessibilityLabel: "Remove \(item.title)") {
                    showDeleteConfirmation = true
                }
            }
        }
    }

    // MARK: - Custom format tags

    private var customFormatTags: some View {
        Color.clear
            .frame(height: 14)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                HStack(spacing: 4) {
                    ForEach(item.customFormats, id: \.self) { cf in
                        Text(cf)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    if item.customFormatScore != 0 {
                        let sign = item.customFormatScore > 0 ? "+" : ""
                        Text("\(sign)\(item.customFormatScore)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(item.customFormatScore > 0 ? .green : .red)
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
            .help(Text(verbatim: customFormatsTooltip))
    }

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

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(rows.count - 1) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
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

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !current.indices.isEmpty && x + size.width > maxWidth {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.indices.append(i)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }
}

// MARK: - Rich tooltip

struct QueueItemTooltip: View {
    let item: QueueItem
    var apiKey: String? = nil
    var locale: Locale = Locale(identifier: "en")

    private func loc(_ key: String) -> String { LocaleBundle.string(key, locale: locale) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemotePoster(
                url: item.posterURL,
                apiKey: apiKey,
                size: posterSize,
                cornerRadius: 6,
                fallbackSymbol: fallbackSymbol
            )
            tooltipContent
        }
        .padding(12)
        .frame(width: 480)
        .background(.regularMaterial)
    }

    private var posterSize: CGSize {
        switch item.source {
        case .radarr, .sonarr: return CGSize(width: 110, height: 165)
        case .lidarr: return CGSize(width: 110, height: 110)
        }
    }

    private var fallbackSymbol: String {
        switch item.source {
        case .radarr: return "film"
        case .sonarr: return "tv"
        case .lidarr: return "music.note"
        }
    }

    private var tooltipContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider().opacity(0.5)
            infoGrid

            if !item.customFormats.isEmpty || item.customFormatScore != 0 {
                tagsSection(
                    label: "Custom formats",
                    score: item.customFormatScore != 0 ? item.customFormatScore : nil,
                    tags: item.customFormats
                )
            }

            if item.isUpgrade,
               item.existingCustomFormatScore != nil
                || item.existingQuality != nil
                || !item.existingCustomFormats.isEmpty {
                upgradeDivider
                Text(verbatim: loc("Existing file"))
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
            Text(verbatim: loc("Upgrade"))
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
        if !item.existingCustomFormats.isEmpty || (item.existingCustomFormatScore ?? 0) != 0 {
            TooltipFlowLayout(spacing: 3) {
                ForEach(item.existingCustomFormats, id: \.self) { TagChip(text: $0) }
                if let s = item.existingCustomFormatScore, s != 0 {
                    let sign = s > 0 ? "+" : ""
                    TagChip(text: "\(sign)\(s)", color: s > 0 ? .green : .red)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func tagsSection(label: String, score: Int?, tags: [String]) -> some View {
        if !tags.isEmpty || score != nil {
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

private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, valueColor: Color? = nil, mono: Bool = false, wraps: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(verbatim: loc(label))
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

struct TagChip: View {
    let text: String
    var color: Color = .primary

    var body: some View {
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

struct TooltipFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(rows.count - 1) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
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
struct HoverActionOverlay<Actions: View>: ViewModifier {
    let visible: Bool
    @ViewBuilder let actions: () -> Actions

    func body(content: Content) -> some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            if visible {
                actions()
                    .padding(.leading, 6)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .windowBackgroundColor).opacity(0),
                                Color(nsColor: .windowBackgroundColor).opacity(0.95),
                                Color(nsColor: .windowBackgroundColor).opacity(0.95),
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

extension View {
    func hoverActions<Actions: View>(
        visible: Bool,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        modifier(HoverActionOverlay(visible: visible, actions: actions))
    }
}

struct IconButton: View {
    @EnvironmentObject var configStore: ConfigStore
    let symbol: String
    let helpKey: String
    var accessibilityLabel: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
        }
        .modifier(GlassButtonStyle())
        .controlSize(.mini)
        .localizedHelp(helpKey, locale: configStore.currentLocale)
        .accessibilityLabel(
            accessibilityLabel.isEmpty
                ? Text(verbatim: LocaleBundle.string(helpKey, locale: configStore.currentLocale))
                : Text(verbatim: accessibilityLabel)
        )
    }
}
