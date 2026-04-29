import SwiftUI

struct HistoryView: View {
    let source: QueueItem.Source
    @ObservedObject var viewModel: QueueViewModel
    let refreshNonce: Int
    let onClose: () -> Void

    @State private var items: [HistoryItem] = []
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: refreshNonce) { await load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: sourceSymbol)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text(LocalizedStringKey(sourceTitle))
                .font(.system(size: 12, weight: .semibold))
            Text("History")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(12)
        } else if items.isEmpty {
            Text("No history")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        HistoryRowView(item: item)
                        Divider().padding(.horizontal, 12).opacity(0.5)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: 480)
        }
    }

    private var sourceSymbol: String {
        switch source {
        case .radarr: return "film"
        case .sonarr: return "tv"
        case .lidarr: return "music.note"
        }
    }

    private var sourceTitle: String {
        switch source {
        case .radarr: return "Radarr"
        case .sonarr: return "Sonarr"
        case .lidarr: return "Lidarr"
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        let result = await viewModel.fetchHistory(for: source)
        self.items = result.items
        self.error = result.error
        isLoading = false
    }

    init(source: QueueItem.Source, viewModel: QueueViewModel, refreshNonce: Int, onClose: @escaping () -> Void) {
        self.source = source
        self.viewModel = viewModel
        self.refreshNonce = refreshNonce
        self.onClose = onClose
    }
}

struct HistoryHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct HistoryRowView: View {
    let item: HistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.eventType.symbol)
                .font(.system(size: 11))
                .foregroundStyle(eventTint)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let sub = item.subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let src = item.sourceTitle, !src.isEmpty {
                    Text(src)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 3) {
                    Text(LocalizedStringKey(item.eventType.displayName))
                        .foregroundStyle(eventTint)
                    if let q = item.quality, !q.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(q).foregroundStyle(.tertiary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(relativeDate).foregroundStyle(.tertiary)
                }
                .font(.system(size: 10))
                .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .help(tooltip)
    }

    private var eventTint: Color {
        switch item.eventType {
        case .grabbed: return .blue
        case .imported: return .green
        case .failed: return .red
        case .deleted: return .orange
        case .other: return .secondary
        }
    }

    private var relativeDate: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: item.date, relativeTo: Date())
    }

    private var tooltip: String {
        var lines = [item.title]
        if let sub = item.subtitle { lines.append(sub) }
        if let src = item.sourceTitle { lines.append(src) }
        lines.append("")
        lines.append(item.date.formatted(date: .abbreviated, time: .shortened))
        if let q = item.quality { lines.append("\(String(localized: "Quality:")) \(q)") }
        if item.customFormatScore != 0 {
            let sign = item.customFormatScore > 0 ? "+" : ""
            lines.append("\(String(localized: "Score:")) \(sign)\(item.customFormatScore)")
        }
        if !item.customFormats.isEmpty {
            let tags = item.customFormats.map { "[\($0)]" }.joined()
            lines.append("\(String(localized: "Custom formats:")) \(tags)")
        }
        return lines.joined(separator: "\n")
    }
}
