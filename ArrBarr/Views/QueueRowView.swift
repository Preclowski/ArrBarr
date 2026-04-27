import SwiftUI

struct QueueRowView: View {
    let item: QueueItem
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    @State private var isHovering = false
    @State private var showDeleteConfirmation = false

    private var canControl: Bool {
        switch item.downloadProtocol {
        case .usenet: return configStore.sabnzbd.isConfigured && !configStore.sabnzbd.apiKey.isEmpty
        case .torrent: return configStore.qbittorrent.isConfigured
        case .unknown: return false
        }
    }

    private var canPauseResume: Bool {
        item.status == .downloading || item.status == .paused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(item.isUpgrade ? "Upgrade" : "New")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(item.isUpgrade ? .orange : .green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                (item.isUpgrade ? Color.orange : Color.green).opacity(0.15),
                                in: Capsule()
                            )
                    }

                    if let sub = item.subtitle {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 3) {
                        Image(systemName: statusSymbol)
                            .foregroundStyle(progressTint)
                            .font(.system(size: 8))
                        Text(item.status.displayName)
                            .foregroundStyle(progressTint)
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
                Spacer(minLength: 4)
                if isHovering {
                    actionButtons
                        .transition(.opacity)
                }
            }

            if !item.customFormats.isEmpty {
                customFormatTags
                    .padding(.top, 2)
            }

            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .tint(progressTint)
                .frame(height: 3)
                .padding(.top, item.customFormats.isEmpty ? 0 : 2)
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
        }
        .help(tooltipText)
        .alert("Remove download?", isPresented: $showDeleteConfirmation) {
            Button("Remove", role: .destructive) {
                Task { await viewModel.delete(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(item.title)\" from the download client.")
        }
    }

    // MARK: - Actions

    private var webURL: URL? {
        guard let slug = item.contentSlug else { return nil }
        let cfg = item.source == .radarr ? configStore.radarr : configStore.sonarr
        let path = item.source == .radarr ? "/movie/\(slug)" : "/series/\(slug)"
        return URL(string: cfg.baseURL)?.appendingPathComponent(path)
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if let url = webURL {
                IconButton(symbol: "safari", help: "Open in browser", accessibilityLabel: "Open \(item.title) in browser") {
                    NSWorkspace.shared.open(url)
                }
            }
            if canControl && canPauseResume {
                if item.isPaused {
                    IconButton(symbol: "play.fill", help: "Resume", accessibilityLabel: "Resume \(item.title)") {
                        Task { await viewModel.resume(item) }
                    }
                } else {
                    IconButton(symbol: "pause.fill", help: "Pause", accessibilityLabel: "Pause \(item.title)") {
                        Task { await viewModel.pause(item) }
                    }
                }
            }
            if canControl {
                IconButton(symbol: "trash", help: "Remove from client", accessibilityLabel: "Remove \(item.title)") {
                    showDeleteConfirmation = true
                }
            }
        }
    }

    // MARK: - Custom format tags

    private var customFormatTags: some View {
        FlowLayout(spacing: 4) {
            ForEach(item.customFormats, id: \.self) { cf in
                Text(cf)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            if item.customFormatScore != 0 {
                let sign = item.customFormatScore > 0 ? "+" : ""
                Text("\(sign)\(item.customFormatScore)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(item.customFormatScore > 0 ? .green : .red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    // MARK: - Display helpers

    private var metaLine: String {
        var parts: [String] = []
        if let q = item.quality, !q.isEmpty { parts.append(q) }
        if let t = item.timeLeft, !t.isEmpty, t != "00:00:00" { parts.append(t) }
        let sizeStr = ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file)
        parts.append(sizeStr)
        return parts.joined(separator: " · ")
    }

    private var statusSymbol: String {
        switch item.status {
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .queued: return "clock.fill"
        case .completed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tooltipText: String {
        var lines: [String] = [item.title]
        if let sub = item.subtitle { lines.append(sub) }
        lines.append("")

        if let q = item.quality, !q.isEmpty { lines.append("Quality: \(q)") }
        if let client = item.downloadClient { lines.append("Client: \(client) (\(item.downloadProtocol.rawValue))") }
        if item.customFormatScore != 0 {
            let sign = item.customFormatScore > 0 ? "+" : ""
            lines.append("Score: \(sign)\(item.customFormatScore)")
        }
        if !item.customFormats.isEmpty {
            lines.append("")
            lines.append("Custom formats:")
            for cf in item.customFormats { lines.append("  • \(cf)") }
        }
        return lines.joined(separator: "\n")
    }

    private var progressTint: Color {
        switch item.status {
        case .paused: return .orange
        case .failed, .warning: return .red
        case .completed: return .green
        default: return .blue
        }
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

private struct IconButton: View {
    let symbol: String
    let help: String
    var accessibilityLabel: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .modifier(GlassButtonStyle())
        .controlSize(.mini)
        .help(help)
        .accessibilityLabel(accessibilityLabel.isEmpty ? help : accessibilityLabel)
    }
}
