import SwiftUI

struct HistoryView: View {
    /// nil = "All" — merge history across every configured arr (iOS filter).
    /// macOS passes a concrete source (per-arr "Show history").
    let source: QueueItem.Source?
    /// One library record's history (a detail view's "Show history") — the
    /// arr filters server-side, so it pages like the arr-wide feed. Needs a
    /// concrete `source`.
    var entityId: Int? = nil
    /// Header title override — the record's title when `entityId` is set.
    var title: String? = nil
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    let onClose: () -> Void
    /// macOS panel / popover shows its own back-button header; the iOS
    /// History tab supplies a nav bar + source filter instead, so it hides it.
    var showHeader: Bool = true
    /// Optional event-type filter (nil = all types). Driven by the iOS
    /// History tab's second filter menu.
    var typeFilter: HistoryItem.EventType? = nil
    /// Opens a row's title. The host pushes it onto its own stack so Back
    /// returns to this list; nil leaves the rows inert.
    var onOpenDetail: ((QueueItem) -> Void)? = nil

    var body: some View {
        // Header in the safe area, not as a stacked row: the rows scroll under
        // it and the system blurs the seam, like every other surface here.
        content(feed)
            .safeAreaBar(edge: .top, spacing: 0) {
                if showHeader { header }
            }
        // The feed outlives this view, so a reopened popover shows the rows it
        // had at once; this brings them up to date behind them. Re-run when the
        // iOS tab swaps `source` in place.
        .task(id: "\(source?.rawValue ?? "all")/\(entityId.map(String.init) ?? "")") { await feed.load() }
    }

    /// Arrs the user has configured — used to fan out the "All" load.
    private var availableSources: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible }
    }

    private var feed: HistoryFeed {
        viewModel.historyFeed(for: source.map { [$0] } ?? availableSources, entityId: entityId)
    }

    /// Loaded items after the optional event-type filter.
    private func shownItems(_ feed: HistoryFeed) -> [HistoryItem] {
        guard let typeFilter else { return feed.items }
        return feed.items.filter { $0.eventType == typeFilter }
    }

    private var header: some View {
        // The self-drawn header every pushed surface shares (DetailView,
        // SeasonDetailView, SearchAddPanel): back chevron + one semibold title.
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

    /// "History (Radarr)". `AppLocalized` rather than `String(localized:)` so
    /// a live language switch reaches it.
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
            // Center vertically in the remaining popover area instead
            // of pinning a 28pt top margin under the header — that read
            // as a "dead zone" when the back button was the only thing
            // anchoring the eye to the top.
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

    /// The inset the queue's plain `List` adds to every row on macOS, on top
    /// of the row's own `queueRowH` — queue rows land 15 pt from the popover
    /// edge. History is a ScrollView (see `list`), so it adds the same inset
    /// itself to line up with the queue. iOS honours the queue's zero insets.
    #if os(macOS)
    private static let queueListInset: CGFloat = 8
    #else
    private static let queueListInset: CGFloat = 0
    #endif

    /// A ScrollView + LazyVStack, like Upcoming and Library — not a `List`.
    /// The macOS List is an NSTableView that re-estimates every row height as
    /// rows scroll in and whenever the data changes; with rows of differing
    /// heights and batches landing while scrolling, the scroller jumped back
    /// and forth.
    private func list(_ feed: HistoryFeed, rows: [HistoryItem]) -> some View {
        let groups = HistoryItem.grouped(rows, now: feed.loadedAt ?? Date())
        // The next batch is asked for as one of the last few rows comes into
        // view — once per batch, since the rows it adds push the new tail out
        // of sight — so it's usually in before the list reaches the end.
        let prefetchIDs = Set(rows.suffix(5).map(\.id))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    sectionHeader(group.bucket, isFirst: group.id == groups.first?.id)
                    ForEach(group.items) { item in
                        HistoryRowView(item: item, showSourceBadge: source == nil, onOpenDetail: onOpenDetail)
                            // `PosterMetadataRow` pads itself 12 pt; top that
                            // up to the queue row's edge.
                            .padding(.horizontal, Tokens.Spacing.queueRowH + Self.queueListInset - 12)
                            .onAppear {
                                if prefetchIDs.contains(item.id) { feed.requestMore() }
                            }
                    }
                }
                // A filter that hides every loaded row has no tail row to
                // trigger the next batch, so the footer asks instead.
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
        // Content blurs softly under the floating glass chrome instead of
        // being cut off by it — same treatment as the queue.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .frame(maxHeight: .infinity)
    }

    /// "3 hours ago", styled like the Upcoming tab's day headers. The rows
    /// under it carry no time of their own.
    private func sectionHeader(_ bucket: HistoryItem.TimeBucket, isFirst: Bool) -> some View {
        Text(verbatim: sectionTitle(bucket))
            .scaledFont(size: 11, weight: .semibold)
            // Same level as every other section title — see `DetailSectionHeader`.
            .foregroundStyle(.primary)
            .padding(.horizontal, Tokens.Spacing.queueRowH + Self.queueListInset)
            .padding(.top, isFirst ? 8 : 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func sectionTitle(_ bucket: HistoryItem.TimeBucket) -> String {
        let locale = configStore.currentLocale
        // Shared, not built here: this runs per section header per body pass —
        // i.e. while the list scrolls — and a formatter costs far more to
        // allocate and configure than to use.
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

/// One history event at the Upcoming rows' sizes (26×38 poster, 12 pt title,
/// 10 pt metadata) in the queue row's arrangement: poster and text top-aligned,
/// the event chip on the title line's trailing edge, client · quality · size
/// below, and for a release that was grabbed or imported, the format chips with
/// the score pinned to the row's trailing edge. Not `PosterMetadataRow`: that
/// centres the text on the poster and parks its accessory in a column of its
/// own, which leaves no full-width line for the chip strip. Time lives in the
/// section header; the upgrade diff in the tooltip.
struct HistoryRowView: View {
    let item: HistoryItem
    /// Show the item's arr icon (used by the "All" history filter where rows
    /// from different services are interleaved).
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
        // Same insets as `PosterMetadataRow`; the list adds the rest to reach
        // the queue row's edge.
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .modifier(RowTapToOpen(action: openAction))
        .linkRowHover()
        .hoverTooltip { HistoryItemTooltip(item: item, apiKey: apiKey) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(openAction != nil ? .isButton : [])
    }

    /// "Show · S01E02 · Title", or "Show · Season 1 · 3 episodes" on a folded
    /// batch — the queue row's one-line identity.
    private var rowTitle: String {
        [item.title, item.subtitle.flatMap { $0.isEmpty ? nil : $0 }, groupedCountText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// A deletion's or failure's formats and score describe a file that's gone
    /// or never arrived — only a release that was grabbed or imported shows them.
    private var describesRelease: Bool {
        item.eventType == .grabbed || item.eventType == .imported
    }

    /// Quality · size.
    private var metadataSegments: [String] {
        [
            item.quality.flatMap { $0.isEmpty ? nil : $0 },
            item.size.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil },
        ].compactMap { $0 }
    }

    /// The queue row's format strip: chips on one line fading out at the edge,
    /// the score pinned trailing.
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

    /// "12 tracks" / "8 episodes" on a folded batch; nil on plain rows.
    private var groupedCountText: String? {
        guard item.groupedCount > 1 else { return nil }
        let unitKey = item.source == .lidarr ? "unit.tracks" : "unit.episodes"
        return String.localizedStringWithFormat(
            NSLocalizedString(unitKey, bundle: .module, comment: ""), item.groupedCount)
    }

    /// The Upcoming row's poster box: 2:3, square for Lidarr covers.
    private var posterSize: CGSize {
        item.source == .lidarr ? CGSize(width: 26, height: 26) : CGSize(width: 26, height: 38)
    }

    private var apiKey: String? {
        item.posterRequiresAuth ? configStore.config(for: item.source).apiKey : nil
    }
}

/// Long-hover card for a history event, shaped like `QueueItemTooltip`: a grab
/// or import that replaced a file leads with the side-by-side upgrade diff; any
/// other event gets the plain quality / size grid, format chips and release.
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
            // Corner grammar: [context: client][status: the event].
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

    /// Grabs and imports compare against the file they replaced. A deletion
    /// is itself the old side of some upgrade, and a failure replaced nothing.
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
        // The diff already carries quality and size for both sides.
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

    /// The release the event is about. Import and deletion rows can carry a
    /// file path here instead, and only its last component names anything.
    private var releaseName: String? {
        guard let title = item.sourceTitle, !title.isEmpty else { return nil }
        return Self.lastComponent(title)
    }

    private static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

private extension HistoryItem.EventType {
    /// Blue grabbed / green imported / red failed / orange deleted — the row's
    /// chip and the tooltip's wear the same one.
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
