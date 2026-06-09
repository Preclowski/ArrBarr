import SwiftUI

public struct HistoryView: View {
    /// nil = "All" — merge history across every configured arr (iOS filter).
    /// macOS passes a concrete source (per-arr "Show history").
    let source: QueueItem.Source?
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    let refreshNonce: Int
    let onClose: () -> Void
    /// macOS panel / popover shows its own back-button header; the iOS
    /// History tab supplies a nav bar + source filter instead, so it hides it.
    var showHeader: Bool = true
    /// Optional event-type filter (nil = all types). Driven by the iOS
    /// History tab's second filter menu.
    var typeFilter: HistoryItem.EventType? = nil

    @State private var items: [HistoryItem] = []
    @State private var error: String?
    @State private var isLoading = true

    public var body: some View {
        VStack(spacing: 0) {
            if showHeader { header }
            content
        }
        // Re-load when the selected source changes too (the iOS tab swaps
        // `source` in place), not only on an explicit refresh nonce.
        .task(id: "\(source?.rawValue ?? "all")#\(refreshNonce)") { await load() }
    }

    /// Arrs the user has configured — used to fan out the "All" load.
    private var availableSources: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible }
    }

    /// Loaded items after the optional event-type filter.
    private var shownItems: [HistoryItem] {
        guard let typeFilter else { return items }
        return items.filter { $0.eventType == typeFilter }
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
            Text("discover.history.button", bundle: .module)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
            Spacer()
            if let source {
                ServiceIcon(source: source, size: 11)
                    .foregroundStyle(.tertiary)
            }
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
        } else if shownItems.isEmpty {
            Text("common.noHistory.button", bundle: .module)
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
                    ForEach(shownItems) { item in
                        HistoryRowView(item: item, showSourceBadge: source == nil)
                        Divider().padding(.horizontal, 12).opacity(0.5)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
    }

    private var sourceTitle: String {
        switch source {
        case .radarr: return "Radarr"
        case .sonarr: return "Sonarr"
        case .lidarr: return "Lidarr"
        case .whisparr: return "Whisparr"
        case nil: return "All"
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        if let source {
            let result = await viewModel.fetchHistory(for: source)
            self.items = result.items
            self.error = result.error
        } else {
            // "All" — fan out across every configured arr, merge, newest first.
            var merged: [HistoryItem] = []
            var errors: [String] = []
            for s in availableSources {
                let r = await viewModel.fetchHistory(for: s)
                merged.append(contentsOf: r.items)
                if let e = r.error { errors.append(e) }
            }
            self.items = merged.sorted { $0.date > $1.date }
            // Only surface an error when nothing loaded at all.
            self.error = (merged.isEmpty && !errors.isEmpty) ? errors.joined(separator: " · ") : nil
        }
        isLoading = false
    }

    init(source: QueueItem.Source?, viewModel: QueueViewModel, refreshNonce: Int, showHeader: Bool = true, typeFilter: HistoryItem.EventType? = nil, onClose: @escaping () -> Void) {
        self.source = source
        self.viewModel = viewModel
        self.refreshNonce = refreshNonce
        self.showHeader = showHeader
        self.typeFilter = typeFilter
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
    /// Show the item's arr icon (used by the "All" history filter where rows
    /// from different services are interleaved).
    var showSourceBadge: Bool = false

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
            // Arr icon on the trailing edge (All-filter view) — tells you
            // which service the row came from without leading clutter.
            if showSourceBadge {
                ServiceIcon(source: item.source, size: 13)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
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
        if let q = item.quality { lines.append("\(String(localized: "history.quality.button", bundle: .module)) \(q)") }
        if item.customFormatScore != 0 {
            let sign = item.customFormatScore > 0 ? "+" : ""
            lines.append("\(String(localized: "history.score.button", bundle: .module)) \(sign)\(item.customFormatScore)")
        }
        if !item.customFormats.isEmpty {
            let tags = item.customFormats.map { "[\($0)]" }.joined()
            lines.append("\(String(localized: "history.customFormats.button", bundle: .module)) \(tags)")
        }
        return lines.joined(separator: "\n")
    }
}
