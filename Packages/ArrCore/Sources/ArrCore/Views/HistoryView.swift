import SwiftUI

public struct HistoryView: View {
    let source: QueueItem.Source
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    let refreshNonce: Int
    let onClose: () -> Void

    @State private var items: [HistoryItem] = []
    @State private var error: String?
    @State private var isLoading = true

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .task(id: refreshNonce) { await load() }
    }

    private var header: some View {
        // Variant A header: back chevron + prominent page title on the
        // leading edge, source pill pushed right as a context tag.
        // Same pattern in DetailView + SearchAddPanel. The old layout
        // (`Spacer` between back and a three-token tertiary string on
        // the right — `🎬 Radarr Historia`) had no actual page title,
        // just scattered metadata.
        HStack(spacing: 6) {
            FloatingBackButton(action: onClose)
            Text("History", bundle: .module)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: sourceSymbol)
                .scaledFont(size: 11)
                .foregroundStyle(.tertiary)
            Text(LocalizedStringKey(sourceTitle))
                .scaledFont(size: 11)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            // Center vertically in the remaining popover area instead
            // of pinning a 28pt top margin under the header — that read
            // as a "dead zone" when the back button was the only thing
            // anchoring the eye to the top.
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…", bundle: .module).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .scaledFont(size: 11)
                .foregroundStyle(.orange)
                .padding(12)
        } else if items.isEmpty {
            Text("No history", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // LazyVStack used to add 4pt vertical padding around the
            // first/last rows; the row itself already carries
            // padding(.vertical, 6) so 4+6=10pt above the first row
            // read as an unnecessary gap. Let the rows own their
            // spacing for a flush header→content transition.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        HistoryRowView(item: item)
                        Divider().padding(.horizontal, 12).opacity(0.5)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
    }

    private var sourceSymbol: String {
        switch source {
        case .radarr: return "film"
        case .sonarr: return "tv"
        case .lidarr: return "music.note"
        case .whisparr: return "flame"
        }
    }

    private var sourceTitle: String {
        switch source {
        case .radarr: return "Radarr"
        case .sonarr: return "Sonarr"
        case .lidarr: return "Lidarr"
        case .whisparr: return "Whisparr"
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

public struct HistoryHeightKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

public struct HistoryRowView: View {
    let item: HistoryItem

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.eventType.symbol)
                .scaledFont(size: 11)
                .foregroundStyle(eventTint)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(1)
                if let sub = item.subtitle {
                    Text(sub)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let src = item.sourceTitle, !src.isEmpty {
                    Text(src)
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 3) {
                    Text(LocalizedStringKey(item.eventType.displayName))
                        .foregroundStyle(eventTint)
                    if let q = item.quality, !q.isEmpty {
                        SeparatorDot()
                        Text(q).foregroundStyle(.tertiary)
                    }
                    SeparatorDot()
                    Text(relativeDate).foregroundStyle(.tertiary)
                }
                .scaledFont(size: 10)
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
