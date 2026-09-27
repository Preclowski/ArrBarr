import SwiftUI

struct HistoryView: View {
    /// nil = "All", merged across every configured arr (iOS filter).
    let source: QueueItem.Source?
    /// One record's history; the arr filters server-side. Needs a concrete `source`.
    var entityId: Int? = nil
    var title: String? = nil
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    let onClose: () -> Void
    /// The iOS History tab supplies its own nav bar and filter instead.
    var showHeader: Bool = true
    var typeFilter: HistoryItem.EventType? = nil
    /// The host pushes onto its own stack so Back returns here; nil leaves rows inert.
    var onOpenDetail: ((QueueItem) -> Void)? = nil

    var body: some View {
        content(feed)
            .safeAreaBar(edge: .top, spacing: 0) {
                if showHeader { header }
            }
        // The feed outlives this view, so a reopened popover shows its rows at once; re-run when iOS swaps `source`.
        .task(id: "\(source?.rawValue ?? "all")/\(entityId.map(String.init) ?? "")") { await feed.load() }
    }

    private var availableSources: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible }
    }

    private var feed: HistoryFeed {
        viewModel.historyFeed(for: source.map { [$0] } ?? availableSources, entityId: entityId)
    }

    private func shownItems(_ feed: HistoryFeed) -> [HistoryItem] {
        guard let typeFilter else { return feed.items }
        return feed.items.filter { $0.eventType == typeFilter }
    }

    private var header: some View {
        HStack(spacing: 6) {
            FloatingBackButton(action: onClose)
                .keyboardShortcut(.cancelAction)
            Text(verbatim: headerTitle)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// `AppLocalized` rather than `String(localized:)` so a live language switch reaches it.
    private var headerTitle: String {
        if let title { return title }
        let history = AppLocalized.string("discover.history.button", locale: configStore.currentLocale)
        guard let source else { return history }
        return "\(history) (\(source.displayName))"
    }

    @ViewBuilder
    private func content(_ feed: HistoryFeed) -> some View {
        let rows = shownItems(feed)
        if feed.items.isEmpty && (feed.isLoading || feed.loadedAt == nil) {
            LoadingStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if feed.items.isEmpty, let error = feed.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .scaledFont(size: 11)
                .foregroundStyle(.orange)
                .padding(12)
        } else if rows.isEmpty && !feed.hasMore {
            Text("common.noHistory.button", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list(feed, rows: rows)
        }
    }

    /// Matches the inset the queue's macOS `List` adds per row, since this is a ScrollView.
    #if os(macOS)
    private static let queueListInset: CGFloat = 8
    #else
    private static let queueListInset: CGFloat = 0
    #endif

    /// Not a `List`: the macOS NSTableView re-estimates row heights while batches land, and the scroller jumped.
    private func list(_ feed: HistoryFeed, rows: [HistoryItem]) -> some View {
        let groups = HistoryItem.grouped(rows, now: feed.loadedAt ?? Date())
        // Asked for as one of the last rows appears, so it usually lands before the list reaches the end.
        let prefetchIDs = Set(rows.suffix(5).map(\.id))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    sectionHeader(group.bucket, isFirst: group.id == groups.first?.id)
                    ForEach(group.items) { item in
                        HistoryRowView(item: item, showSourceBadge: source == nil, onOpenDetail: onOpenDetail)
                            .padding(.horizontal, Tokens.Spacing.queueRowH + Self.queueListInset - 12)
                            .onAppear {
                                if prefetchIDs.contains(item.id) { feed.requestMore() }
                            }
                    }
                }
                // A filter that hides every loaded row leaves no tail row to trigger the next batch.
                if feed.isLoadingMore || (rows.isEmpty && feed.hasMore) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .onAppear { feed.requestMore() }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .frame(maxHeight: .infinity)
    }

    private func sectionHeader(_ bucket: HistoryItem.TimeBucket, isFirst: Bool) -> some View {
        Text(verbatim: sectionTitle(bucket))
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(.primary)
            .padding(.horizontal, Tokens.Spacing.queueRowH + Self.queueListInset)
            .padding(.top, isFirst ? 8 : 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func sectionTitle(_ bucket: HistoryItem.TimeBucket) -> String {
        let locale = configStore.currentLocale
        // Shared: this runs per section header per body pass while scrolling, and formatters are costly to create.
        let formatter = CachedDateFormatters.relative(.full, locale: locale)
        switch bucket {
        case .hours(0): return AppLocalized.string("history.bucket.lastHour", locale: locale)
        case .hours(let hours): return formatter.localizedString(from: DateComponents(hour: -hours))
        case .days(let days): return formatter.localizedString(from: DateComponents(day: -days))
        }
    }

    init(source: QueueItem.Source?, entityId: Int? = nil, title: String? = nil,
         viewModel: QueueViewModel, showHeader: Bool = true,
         typeFilter: HistoryItem.EventType? = nil, onOpenDetail: ((QueueItem) -> Void)? = nil,
         onClose: @escaping () -> Void) {
        self.source = source
        self.entityId = entityId
        self.title = title
        self.viewModel = viewModel
        self.showHeader = showHeader
        self.typeFilter = typeFilter
        self.onOpenDetail = onOpenDetail
        self.onClose = onClose
    }
}

/// Not `PosterMetadataRow`: that centres text on the poster and gives the accessory its own column,
/// leaving no full-width line for the format chip strip.
struct HistoryRowView: View {
    let item: HistoryItem
    var showSourceBadge: Bool = false
    var onOpenDetail: ((QueueItem) -> Void)? = nil
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: item.source), cornerRadius: 3) {
                RemotePoster(
                    url: item.posterURL,
                    apiKey: apiKey,
                    tier: .icon,
                    size: posterSize,
                    cornerRadius: 3,
                    fallbackSymbol: item.source.symbol
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: rowTitle)
                        .scaledFont(size: 12, weight: .medium)
                        .lineLimit(1)
                    if openAction != nil {
                        LinkChevron(size: 9)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 4)
                    TagChip(
                        text: AppLocalized.string(item.eventType.labelKey, locale: configStore.currentLocale),
                        color: item.eventType.tint
                    )
                    if showSourceBadge {
                        ServiceIcon(source: item.source, size: 13)
                            .foregroundStyle(.tertiary)
                    }
                }
                if item.downloadClient != nil || !metadataSegments.isEmpty {
                    HStack(spacing: 5) {
                        if let client = item.downloadClient {
                            DownloadClientLabel(name: client)
                        }
                        HStack(spacing: 4) {
                            ForEach(Array(metadataSegments.enumerated()), id: \.offset) { index, segment in
                                if index > 0 { SeparatorDot() }
                                Text(verbatim: segment)
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .scaledFont(size: 10)
                }
                if let formatStrip {
                    formatStrip
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .modifier(RowTapToOpen(action: openAction))
        .linkRowHover()
        .hoverTooltip { HistoryItemTooltip(item: item, apiKey: apiKey) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(openAction != nil ? .isButton : [])
    }

    private var rowTitle: String {
        [item.title, item.subtitle.flatMap { $0.isEmpty ? nil : $0 }, groupedCountText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// A deletion's or failure's formats describe a file that's gone or never arrived.
    private var describesRelease: Bool {
        item.eventType == .grabbed || item.eventType == .imported
    }

    private var metadataSegments: [String] {
        [
            item.quality.flatMap { $0.isEmpty ? nil : $0 },
            item.size.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil },
        ].compactMap { $0 }
    }

    private var formatStrip: AnyView? {
        guard describesRelease, !item.customFormats.isEmpty || item.customFormatScore != 0 else { return nil }
        return AnyView(QueueRowFormatStrip(
            formats: item.customFormats,
            score: item.customFormatScore,
            baseline: item.replaced?.score
        ))
    }

    private var openAction: (() -> Void)? {
        guard let onOpenDetail, let arrId = item.arrId else { return nil }
        let target = DetailRequest.item(
            source: item.source, arrId: arrId, title: item.title,
            posterURL: item.posterURL, posterRequiresAuth: item.posterRequiresAuth
        )
        return { onOpenDetail(target) }
    }

    private var groupedCountText: String? {
        guard item.groupedCount > 1 else { return nil }
        let unitKey = item.source == .lidarr ? "unit.tracks" : "unit.episodes"
        return String.localizedStringWithFormat(
            NSLocalizedString(unitKey, bundle: .module, comment: ""), item.groupedCount)
    }

    private var posterSize: CGSize {
        item.source == .lidarr ? CGSize(width: 26, height: 26) : CGSize(width: 26, height: 38)
    }

    private var apiKey: String? {
        item.posterRequiresAuth ? configStore.config(for: item.source).apiKey : nil
    }
}

private struct HistoryItemTooltip: View {
    let item: HistoryItem
    let apiKey: String?
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        MediaTooltipChrome(
            title: item.title,
            subtitle: item.subtitle,
            posterURL: item.posterURL,
            posterRequiresAuth: apiKey != nil,
            apiKey: apiKey,
            posterSize: MediaTooltipChrome<EmptyView>.posterSize(for: item.source),
            blurred: configStore.shouldBlurPoster(for: item.source),
            fallbackSymbol: item.source.symbol,
            contextChip: item.downloadClient.map { AnyView(DownloadClientLabel(name: $0)) },
            statusChip: AnyView(StateChip(
                text: AppLocalized.string(item.eventType.labelKey, locale: configStore.currentLocale),
                color: item.eventType.tint
            ))
        ) {
            if let baseline = diffBaseline {
                UpgradeDiffView(
                    current: .init(
                        quality: baseline.quality,
                        score: baseline.score,
                        size: baseline.size,
                        formats: baseline.formats,
                        filename: baseline.filename.map(Self.lastComponent)
                    ),
                    incoming: .init(
                        quality: item.quality,
                        score: item.customFormatScore,
                        size: item.size,
                        formats: item.customFormats,
                        filename: releaseName
                    ),
                    showFilenames: true
                )
            }
            TooltipInfoGrid(lines: infoLines)
            if diffBaseline == nil {
                customFormatChipStrip(
                    tags: item.customFormats,
                    score: item.customFormatScore != 0 ? item.customFormatScore : nil
                )
                TooltipFileName(name: releaseName)
            }
        }
    }

    /// A deletion is itself the old side of some upgrade, and a failure replaced nothing.
    private var diffBaseline: HistoryItem.FileSnapshot? {
        guard item.eventType == .grabbed || item.eventType == .imported else { return nil }
        return item.replaced
    }

    private var infoLines: [TooltipInfoLine] {
        var lines = [TooltipInfoLine(
            labelKey: "history.date.label",
            value: item.date.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened).locale(configStore.currentLocale))
        )]
        if diffBaseline == nil {
            if let quality = item.quality, !quality.isEmpty {
                lines.append(TooltipInfoLine(labelKey: "Quality", value: quality))
            }
            if let size = item.size, size > 0 {
                lines.append(TooltipInfoLine(
                    labelKey: "Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
            }
        }
        if let indexer = item.indexer {
            lines.append(TooltipInfoLine(labelKey: "Indexer", value: indexer))
        }
        if item.groupedCount > 1 {
            lines.append(TooltipInfoLine(
                labelKey: item.source == .lidarr ? "library.tracks.label" : "library.episodes.label",
                value: "\(item.groupedCount)"
            ))
        }
        return lines
    }

    /// Import and deletion rows can carry a file path here; only its last component names anything.
    private var releaseName: String? {
        guard let title = item.sourceTitle, !title.isEmpty else { return nil }
        return Self.lastComponent(title)
    }

    private static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

private extension HistoryItem.EventType {
    var tint: Color {
        switch self {
        case .grabbed: return .blue
        case .imported: return .green
        case .failed: return .red
        case .deleted: return .orange
        case .other: return .secondary
        }
    }
}
