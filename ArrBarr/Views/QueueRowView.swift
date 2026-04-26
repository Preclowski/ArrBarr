import SwiftUI

struct QueueRowView: View {
    let item: QueueItem
    @ObservedObject var viewModel: QueueViewModel
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let sub = item.subtitle {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(metaLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                actionButtons
                    .opacity(isHovering ? 1 : 0.35)
            }

            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .tint(progressTint)
                .frame(height: 3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Natywny systemowy tooltip — pojawia się po krótkiej zwłoce hover.
        // Multiline string zawiera custom formaty + score + szczegóły release'u.
        .help(tooltipText)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if item.isPaused {
                IconButton(symbol: "play.fill", help: "Resume") {
                    Task { await viewModel.resume(item) }
                }
            } else {
                IconButton(symbol: "pause.fill", help: "Pause") {
                    Task { await viewModel.pause(item) }
                }
            }
            IconButton(symbol: "trash", help: "Remove from client") {
                Task { await viewModel.delete(item) }
            }
        }
    }

    // MARK: - Display helpers

    private var metaLine: String {
        var parts: [String] = []
        parts.append(item.status.displayName)
        if let q = item.quality, !q.isEmpty { parts.append(q) }
        if item.customFormatScore != 0 {
            let sign = item.customFormatScore > 0 ? "+" : ""
            parts.append("CF \(sign)\(item.customFormatScore)")
        }
        if let t = item.timeLeft, !t.isEmpty, t != "00:00:00" { parts.append(t) }
        let sizeStr = ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file)
        parts.append(sizeStr)
        return parts.joined(separator: " · ")
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

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovering ? Color.primary.opacity(0.15) : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}
