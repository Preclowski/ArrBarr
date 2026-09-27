import os
import SwiftUI
import MediaKit

/// On touch the popover-sized chrome gives 20pt hit areas (half Apple's 44pt minimum),
/// so every value is forked here rather than `#if`-ed at each call site.
private enum LibraryChrome {
    #if os(iOS)
    static let label: CGFloat = 13
    static let chevron: CGFloat = 10
    static let chipHPad: CGFloat = 12
    static let chipVPad: CGFloat = 8
    static let glyph: CGFloat = 15
    static let tapTarget: CGFloat = 44
    static let brandIcon: CGFloat = 13
    #else
    static let label: CGFloat = 11
    static let chevron: CGFloat = 8
    static let chipHPad: CGFloat = 8
    static let chipVPad: CGFloat = 3
    static let glyph: CGFloat = 11
    static let tapTarget: CGFloat = 20
    static let brandIcon: CGFloat = 10
    #endif
}

#if os(iOS)
/// `isSearching` is only readable from inside the searchable content, hence the wrapper.
private struct LibraryFilterStrip<Content: View>: View {
    @Environment(\.isSearching) private var isSearching
    @ViewBuilder var content: () -> Content

    var body: some View {
        if !isSearching { content() }
    }
}
#else
private struct LibraryFilterStrip<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
#endif

// MARK: - Browsing state

private enum ViewMode: String { case grid, list }

private enum StatusFilter: CaseIterable {
    case all, missing, unmonitored

    var cacheKey: String { String(describing: self) }

    var labelKey: String {
        switch self {
        case .all: return "search.all.button"
        case .missing: return "search.missing.button"
        case .unmonitored: return "Unmonitored"
        }
    }
}

private enum SortMode: CaseIterable {
    case title, releaseDate, dateAdded, size, imdb, tmdb, rating

    /// Must stay 1:1 with `areInIncreasingOrder`; "title" is also the view model's pre-warm key.
    var cacheKey: String { String(describing: self) }

    /// Every axis is ascending; the view's direction flag decides how it is read,
    /// so the direction survives a change of axis.
    var areInIncreasingOrder: (LibraryEntry, LibraryEntry) -> Bool {
        switch self {
        case .title:
            return LibraryViewModel.titleAscending
        case .releaseDate:
            // Undated entries sort as oldest so they gather at one end.
            return { ($0.releaseSortKey, $0.title) < ($1.releaseSortKey, $1.title) }
        case .dateAdded:
            return { ($0.dateAdded ?? .distantPast, $0.title) < ($1.dateAdded ?? .distantPast, $1.title) }
        case .size:
            return { $0.sizeOnDisk < $1.sizeOnDisk }
        case .imdb:
            return { ($0.ratingImdb ?? -1) < ($1.ratingImdb ?? -1) }
        case .tmdb:
            return { ($0.ratingTmdb ?? -1) < ($1.ratingTmdb ?? -1) }
        case .rating:
            return { ($0.ratingArr ?? -1) < ($1.ratingArr ?? -1) }
        }
    }

    var label: Text {
        switch self {
        case .title: return Text("library.sort.title", bundle: .module)
        case .releaseDate: return Text("library.sort.releaseDate", bundle: .module)
        case .dateAdded: return Text("library.sort.dateAdded", bundle: .module)
        case .size: return Text("queue.size.button", bundle: .module)
        case .imdb: return Text(verbatim: "IMDb")
        case .tmdb: return Text(verbatim: "TMDB")
        case .rating: return Text("Rating", bundle: .module)
        }
    }

    /// Plain `Image(systemName:)` only: a menu row drops any other image view.
    /// `.rating` is the single score the source ships (TVDB for Sonarr), so a plain star.
    var symbolName: String {
        switch self {
        case .title: return "textformat"
        case .releaseDate: return "calendar"
        case .dateAdded: return "tray.and.arrow.down"
        case .size: return "internaldrive"
        case .imdb: return "star.square"
        case .tmdb: return "star.circle"
        case .rating: return "star"
        }
    }

    /// Radarr sorts IMDb and TMDB separately; Sonarr and Lidarr ship one score, Whisparr none.
    /// Lidarr has no release date (albums do, artists don't).
    static func available(for source: QueueItem.Source) -> [SortMode] {
        switch source {
        case .radarr: return [.title, .releaseDate, .dateAdded, .size, .imdb, .tmdb]
        case .sonarr: return [.title, .releaseDate, .dateAdded, .size, .rating]
        case .whisparr: return [.title, .releaseDate, .dateAdded, .size]
        case .lidarr: return [.title, .dateAdded, .size, .rating]
        }
    }
}

/// The browsing strip and cover grid; search is wrapped above the tabs by `SearchHost`.
struct LibraryTabContent: View {
    var viewModel: LibraryViewModel
    @EnvironmentObject var configStore: ConfigStore

    @State private var source: QueueItem.Source = .radarr
    @State private var sourceResolved = false
    @State private var statusFilter: StatusFilter = .all
    @State private var sort: SortMode = .title
    /// Not reset on axis change: only picking the selected axis again flips it.
    @State private var sortDescending = false
    @AppStorage("libraryViewMode") private var viewModeRaw = ViewMode.grid.rawValue

    private var viewMode: ViewMode {
        ViewMode(rawValue: viewModeRaw) ?? .grid
    }

    private var availableSources: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible }
    }

    private var allEntries: [LibraryEntry] {
        viewModel.entries[source] ?? []
    }

    private func matches(_ entry: LibraryEntry, filter: StatusFilter) -> Bool {
        switch filter {
        case .all: return true
        // Includes not-yet-available titles; their chip explains why.
        case .missing: return entry.state == .missing || entry.state == .partial || entry.state == .notAvailable
        case .unmonitored: return entry.state == .unmonitored
        }
    }

    private var filterCounts: [StatusFilter: Int] {
        var out: [StatusFilter: Int] = [:]
        for filter in StatusFilter.allCases {
            out[filter] = viewModel.count(source, cacheKey: filter.cacheKey, over: allEntries) {
                matches($0, filter: filter)
            }
        }
        return out
    }

    private var visibleEntries: [LibraryEntry] {
        // Sort first through the memoized cache (the localized title sort costs ~20ms at ~3k entries);
        // filtering keeps order. Title-ascending must equal `LibraryViewModel.defaultSortCacheKey`, the pre-warmed order.
        let axisKey = "\(sort.cacheKey)|\(sortDescending ? "desc" : "asc")"
        let ascending = sort.areInIncreasingOrder
        let comparator: (LibraryEntry, LibraryEntry) -> Bool = sortDescending
            ? { ascending($1, $0) }
            : ascending
        let sorted = viewModel.sorted(source, cacheKey: axisKey, using: comparator)
        // Memoized: re-filtering ~3k records copies the array on every `surface` pass.
        return viewModel.visible(source, cacheKey: "\(axisKey)|\(statusFilter.cacheKey)",
                                 from: sorted) { matches($0, filter: statusFilter) }
    }

    var body: some View {
        surface
        .onAppear {
            // Once only: re-running on every appear would fight a manual pick.
            if !sourceResolved {
                sourceResolved = true
                if let first = availableSources.first, !availableSources.contains(source) {
                    source = first
                }
            }
            Task { await load() }
        }
        .onChange(of: source) { _, _ in
            // An axis the new arr doesn't offer (IMDb on Sonarr) resets rather than sorting on nils.
            if !SortMode.available(for: source).contains(sort) { sort = .title }
            Task { await load() }
        }
    }

    private func load(force: Bool = false) async {
        await viewModel.loadIfNeeded(
            source: source,
            config: configStore.config(for: source.serviceKind),
            force: force
        )
    }

    // MARK: - Grid

    @ViewBuilder
    private func gridOrState(_ entries: [LibraryEntry], phase: Phase) -> some View {
        switch phase {
        case .loading:
            ScrollView {
                LoadingStateView()
                    .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        case .failed:
            emptyState(symbol: "exclamationmark.triangle", textKey: "library.error.title") {
                Button {
                    Task { await load(force: true) }
                } label: {
                    Text("common.retry.button", bundle: .module)
                }
                .modifier(GlassButtonStyle())
            }
        case .empty:
            emptyState(symbol: "books.vertical", textKey: "library.empty.title") { EmptyView() }
        case .content:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewMode == .grid {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(entries) { entry in
                                LibraryTile(entry: entry, apiKey: apiKey(for: entry))
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                LibraryListRow(entry: entry, apiKey: apiKey(for: entry))
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.top, 2)
                    }
                }
                // Keeps the last row clear of the floating capsule.
                .padding(.bottom, 58)
            }
            // The host tears this view down on tab switch, so the position lives on the view model.
            .scrollPosition(id: gridAnchor, anchor: .top)
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .frame(maxHeight: .infinity)
        }
    }

    /// Not `@State`: the scroll view writes this every drag frame, and the model stores it
    /// `@ObservationIgnored` so those writes invalidate nothing.
    private var gridAnchor: Binding<LibraryEntry.ID?> {
        Binding(get: { viewModel.gridAnchor[source] },
                set: { viewModel.gridAnchor[source] = $0 })
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 10, alignment: .top)]
    }

    private func apiKey(for entry: LibraryEntry) -> String? {
        entry.posterRequiresAuth ? configStore.config(for: entry.source.serviceKind).apiKey : nil
    }

    private func emptyState(symbol: String, textKey: String, @ViewBuilder accessory: () -> some View) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .scaledFont(size: 24, weight: .light)
                    .foregroundStyle(.tertiary)
                Text(LocalizedStringKey(textKey), bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                accessory()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Surface

    private enum Phase: Equatable { case loading, failed, empty, content }

    private func phase(_ entries: [LibraryEntry]) -> Phase {
        if allEntries.isEmpty {
            if viewModel.loadFailed.contains(source) { return .failed }
            // A never-projected source counts as loading, or the "empty library" state flashes first.
            if viewModel.entries[source] == nil || viewModel.loading.contains(source) { return .loading }
        }
        return entries.isEmpty ? .empty : .content
    }

    /// No transition between states: an `.id(phase)` cross-fade re-identified the grid and
    /// re-animated covers that were already cached.
    private var surface: some View {
        let entries = visibleEntries
        let phase = phase(entries)
        return gridOrState(entries, phase: phase)
            .safeAreaBar(edge: .top, spacing: 0) {
                LibraryFilterStrip {
                    LibraryFilterBar(sources: availableSources,
                                     counts: filterCounts,
                                     source: $source,
                                     statusFilter: $statusFilter,
                                     sort: $sort,
                                     sortDescending: $sortDescending,
                                     viewModeRaw: $viewModeRaw)
                }
            }
    }
}

// MARK: - Shared entry presentation

private extension LibraryEntry {
    /// Lidarr artist images are square; forcing 2:3 letterboxes them.
    var posterAspect: CGFloat {
        source == .lidarr ? 1 : 2.0 / 3.0
    }

    var isMonitored: Bool { state != .unmonitored }


    func releaseStatusText(locale: Locale) -> String? {
        ArrReleaseStatusLabel.text(releaseStatus, locale: locale)
    }

    /// `includeYear: false` for the list row, whose title line already carries the year.
    func metaText(locale: Locale, includeYear: Bool = true) -> String {
        switch state {
        case .unmonitored:
            return AppLocalized.string("Unmonitored", locale: locale)
        case .notAvailable:
            return AppLocalized.string("library.status.notAvailable", locale: locale)
        case .missing:
            if let total = totalCount, total > 0 {
                return "\(fileCount ?? 0)/\(total)"
            }
            return AppLocalized.string("search.missing.button", locale: locale)
        case .partial:
            return "\(fileCount ?? 0)/\(totalCount ?? 0)"
        case .complete:
            var parts: [String] = []
            if includeYear, let year { parts.append(String(year)) }
            if sizeOnDisk > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: sizeOnDisk, countStyle: .file))
            }
            return parts.joined(separator: " · ")
        }
    }

    var sizeText: String? {
        sizeOnDisk > 0 ? ByteCountFormatter.string(fromByteCount: sizeOnDisk, countStyle: .file) : nil
    }

    func openDetail() {
        DetailRequest.open(source: source, arrId: arrId, title: title,
                           posterURL: posterURL, posterRequiresAuth: posterRequiresAuth)
    }
}

// MARK: - Tile

private struct LibraryTile: View {
    let entry: LibraryEntry
    let apiKey: String?
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        Button {
            entry.openDetail()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                PosterBlurContainer(
                    blurred: configStore.shouldBlurPoster(for: entry.source),
                    cornerRadius: Tokens.Radius.card
                ) {
                    RemotePoster(
                        url: entry.posterURL,
                        apiKey: apiKey,
                        // `.icon`, not `.card`: 288 px covers a ≤160 pt tile at @2x and is already on disk;
                        // `.card` costs ~180 kB per tile (~400 MB for a 3000-title library).
                        tier: .icon,
                        cornerRadius: Tokens.Radius.card,
                        fallbackSymbol: entry.source.symbol,
                        fill: true
                    )
                    .aspectRatio(entry.posterAspect, contentMode: .fit)
                }
                .posterMarks(watched: entry.watched, monitored: entry.isMonitored,
                             cornerRadius: Tokens.Radius.card, ribbonWidth: 10)
                Text(verbatim: entry.title)
                    .scaledFont(size: 11, weight: .semibold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if entry.state == .complete {
                    Text(verbatim: entry.metaText(locale: configStore.currentLocale))
                        .scaledFont(size: 10)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                } else {
                    LibraryStatusChip(entry: entry)
                }
            }
            .opacity(entry.state == .unmonitored ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .libraryTooltip(entry: entry, apiKey: apiKey)
        .accessibilityLabel(Text(verbatim: entry.title))
    }
}

// MARK: - List row

private struct LibraryListRow: View {
    let entry: LibraryEntry
    let apiKey: String?
    @EnvironmentObject var configStore: ConfigStore

    private var rowTitle: String {
        if let year = entry.year {
            return "\(entry.title) (\(year))"
        }
        return entry.title
    }

    private var metadataSegments: [String] {
        var segments: [String] = []
        if let size = entry.sizeText { segments.append(size) }
        // Skipped for partial, where the status chip already shows the count.
        if entry.state != .partial, let total = entry.totalCount, total > 0 {
            segments.append("\(entry.fileCount ?? 0)/\(total)")
        }
        if let quality = entry.fileQuality { segments.append(quality) }
        return segments
    }

    /// A chip, not a bare segment, so it reads as the target rather than another on-disk quality.
    @ViewBuilder
    private var profileBadge: some View {
        if let name = entry.profileName { ProfileChip(name: name) }
    }

    var body: some View {
        PosterMetadataRow(
            posterURL: entry.posterURL,
            posterAPIKey: apiKey,
            posterSize: CGSize(width: 38 * entry.posterAspect, height: 38),
            posterBlurred: configStore.shouldBlurPoster(for: entry.source),
            posterFallbackSymbol: entry.source.symbol,
            // Watched only: the row already dims unmonitored entries, and two marks crowd a 25pt thumbnail.
            posterWatched: entry.watched,
            title: rowTitle,
            metadataSegments: metadataSegments,
            onTap: { entry.openDetail() },
            metadataBadge: { profileBadge }
        ) {
            // Trailing, so the chips line up in a column down the list.
            LibraryStatusChip(entry: entry)
        }
        .opacity(entry.state == .unmonitored ? 0.55 : 1)
        .libraryTooltip(entry: entry, apiKey: apiKey)
    }
}

// MARK: - Status chip

private struct LibraryStatusChip: View {
    let entry: LibraryEntry
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        MediaStateChip(
            state: entry.state,
            have: entry.fileCount,
            total: entry.totalCount,
            locale: configStore.currentLocale
        )
    }
}

// MARK: - Hover tooltip

private extension View {
    func libraryTooltip(entry: LibraryEntry, apiKey: String?) -> some View {
        hoverTooltip { LibraryEntryTooltip(entry: entry, apiKey: apiKey) }
    }
}

/// Library counterpart of `QueueItemTooltip`.
private struct LibraryEntryTooltip: View {
    let entry: LibraryEntry
    let apiKey: String?
    @EnvironmentObject var configStore: ConfigStore
    /// Radarr/Whisparr list endpoints don't compute custom formats, release group or languages;
    /// `/moviefile` does, and the clients cache it per movie.
    @State private var fileDetails: ArrFile?
    /// TMDB-only (see `CountryProvider`); fetching here warms the detail view's cache.
    @State private var countries: [String] = []
    @Environment(\.locale) private var locale

    var body: some View {
        MediaTooltipChrome(
            title: entry.title,
            year: entry.year,
            posterURL: entry.posterURL,
            posterRequiresAuth: apiKey != nil,
            apiKey: apiKey,
            posterSize: MediaTooltipChrome<EmptyView>.posterSize(for: entry.source),
            blurred: configStore.shouldBlurPoster(for: entry.source),
            fallbackSymbol: entry.source.symbol,
            contextChip: entry.releaseStatusText(locale: configStore.currentLocale).map { AnyView(TagChip(text: $0)) },
            statusChip: AnyView(LibraryStatusChip(entry: entry))
        ) {
            if !entry.genres.isEmpty {
                GenreChips(genres: entry.genres)
            }
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TooltipRatingPills(chips: ratingChips)
            TooltipInfoGrid(lines: infoLines)
            TooltipOverview(text: entry.overview)
            if entry.profileName != nil || !formats.isEmpty || formatScore != 0 {
                TooltipFlowLayout(spacing: 3) {
                    if let profile = entry.profileName {
                        ProfileChip(name: profile)
                    }
                    ForEach(formats, id: \.self) { TagChip(text: $0) }
                    if formatScore != 0 {
                        ScoreChip(score: formatScore)
                    }
                }
                .padding(.top, 2)
            }
            TooltipFileName(name: fileDetails?.relativePath ?? entry.fileName)
        }
        .task {
            switch entry.source {
            case .radarr:
                countries = await CountryProvider.movieCountries(
                    tmdbId: entry.externalId, configStore: configStore)
            case .sonarr:
                countries = await CountryProvider.seriesCountries(
                    tmdbId: nil, tvdbId: entry.externalId, configStore: configStore)
            case .lidarr, .whisparr:
                break
            }
        }
        .task {
            guard fileDetails == nil, entry.state == .complete else { return }
            switch entry.source {
            case .radarr:
                fileDetails = await Logger.extras.attempt("library file tooltip") { try await configStore.radarrClient.fetchMovieFile(movieId: entry.arrId) } ?? nil
            case .whisparr:
                fileDetails = await Logger.extras.attempt("library file tooltip") { try await configStore.whisparrClient.fetchMovieFile(movieId: entry.arrId) } ?? nil
            case .sonarr, .lidarr:
                break
            }
        }
    }

    private var formats: [String] {
        if let fetched = fileDetails?.customFormats, !fetched.isEmpty {
            return fetched.map(\.name)
        }
        return entry.customFormats
    }

    private var formatScore: Int {
        fileDetails?.customFormatScore ?? entry.customFormatScore
    }

    private var subtitle: String {
        var parts: [String] = []
        if let runtime = entry.runtime, runtime > 0 {
            parts.append("\(runtime) min")
        }
        if let cert = entry.certification, !cert.isEmpty {
            parts.append(cert)
        }
        parts.append(contentsOf: CountryProvider.displayNames(countries, locale: locale))
        return parts.joined(separator: " · ")
    }

    /// Unlinked: tooltips are hover chrome, not click targets.
    private var ratingChips: [RatingChip] {
        var chips: [RatingChip] = []
        switch entry.source {
        case .radarr, .whisparr:
            chips = [
                entry.ratingImdb.flatMap { RatingChip.imdb($0) },
                entry.ratingTmdb.flatMap { RatingChip.tmdb($0) },
                entry.ratingRt.flatMap { RatingChip.rottenTomatoes($0) },
                entry.ratingMetacritic.flatMap { RatingChip.metacritic($0) },
            ].compactMap { $0 }
        case .sonarr:
            chips = [entry.ratingArr.flatMap { RatingChip.tvdb($0) }].compactMap { $0 }
        case .lidarr:
            break
        }
        return chips
    }

    private var infoLines: [TooltipInfoLine] {
        var lines: [TooltipInfoLine] = []
        if let quality = entry.fileQuality {
            lines.append(TooltipInfoLine(labelKey: "Quality", value: quality))
        }
        if let total = entry.totalCount, total > 0 {
            lines.append(TooltipInfoLine(
                labelKey: entry.source == .lidarr ? "library.tracks.label" : "library.episodes.label",
                value: "\(entry.fileCount ?? 0)/\(total)"
            ))
        }
        if let size = entry.sizeText {
            lines.append(TooltipInfoLine(labelKey: "Size", value: size))
        }
        if let group = fileDetails?.releaseGroup, !group.isEmpty {
            lines.append(TooltipInfoLine(labelKey: "Release group", value: group))
        }
        if let languages = fileDetails?.languages?.compactMap(\.name), !languages.isEmpty {
            lines.append(TooltipInfoLine(labelKey: "Languages", value: languages.joined(separator: ", ")))
        }
        return lines
    }
}

// MARK: - Filter bar

/// A separate struct, not a computed property: it lives in the grid's safe area, and as a
/// computed property it re-ran on every scroll frame. `counts` arrives precomputed for the same reason.
private struct LibraryFilterBar: View {
    let sources: [QueueItem.Source]
    let counts: [StatusFilter: Int]
    @Binding var source: QueueItem.Source
    @Binding var statusFilter: StatusFilter
    @Binding var sort: SortMode
    @Binding var sortDescending: Bool
    @Binding var viewModeRaw: String

    private var viewMode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .grid }

    var body: some View {
        HStack(spacing: 6) {
            if sources.count > 1 {
                sourceMenu
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 14)
            }
            // Localized labels ("Niemonitorowane") overflow 400 pt and would wrap inside the capsules.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(StatusFilter.allCases, id: \.self) { filter in
                        statusChip(filter)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 4)
            viewModeToggle
            sortMenu
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var sourceMenu: some View {
        Menu {
            // A `Picker`, not hand-built rows: brand marks don't draw inside menu rows,
            // and AppKit then owns the selection checkmark.
            Picker(selection: $source) {
                ForEach(sources, id: \.self) { s in
                    Text(verbatim: s.displayName).tag(s)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                // Only menu rows drop artwork; the trigger chip is an ordinary view.
                ServiceIcon(source: source, size: LibraryChrome.brandIcon)
                Text(verbatim: source.displayName)
                    .scaledFont(size: LibraryChrome.label, weight: .semibold)
                Image(systemName: "chevron.down")
                    .scaledFont(size: LibraryChrome.chevron, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, LibraryChrome.chipHPad)
            .padding(.vertical, LibraryChrome.chipVPad)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.30), lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("library.source.help", bundle: .module))
    }

    private func statusChip(_ filter: StatusFilter) -> some View {
        let selected = statusFilter == filter
        let count = counts[filter] ?? 0
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { statusFilter = filter }
        } label: {
            HStack(spacing: 3) {
                Text(LocalizedStringKey(filter.labelKey), bundle: .module)
                    .scaledFont(size: LibraryChrome.label, weight: selected ? .semibold : .medium)
                    .lineLimit(1)
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .scaledFont(size: LibraryChrome.label, weight: .regular)
                        .monospacedDigit()
                        // `.secondary`, not `opacity`: over glass a faded label blends with the backdrop.
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, LibraryChrome.chipHPad)
            .padding(.vertical, LibraryChrome.chipVPad)
            // Flat, not glass: the filter row is a control strip, not floating chrome.
            .background {
                if selected { Capsule().fill(Color.primary.opacity(0.14)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The glyph shows the layout you'd switch to, like Finder.
    private var viewModeToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                viewModeRaw = (viewMode == .grid ? ViewMode.list : .grid).rawValue
            }
        } label: {
            Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                .scaledFont(size: LibraryChrome.glyph, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: LibraryChrome.tapTarget, height: LibraryChrome.tapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(viewMode == .grid ? "library.view.list" : "library.view.grid", bundle: .module))
        .accessibilityLabel(Text(viewMode == .grid ? "library.view.list" : "library.view.grid", bundle: .module))
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            ForEach(SortMode.available(for: source), id: \.self) { mode in
                Button {
                    if sort == mode {
                        sortDescending.toggle()
                    } else {
                        sort = mode
                    }
                } label: {
                    Label {
                        mode.label
                    } icon: {
                        Image(systemName: sort == mode
                              ? (sortDescending ? "arrow.down" : "arrow.up")
                              : mode.symbolName)
                    }
                    // Inside a `Menu` the inherited label style can come out title-only and drop the glyph.
                    .labelStyle(.titleAndIcon)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .scaledFont(size: LibraryChrome.glyph, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: LibraryChrome.tapTarget, height: LibraryChrome.tapTarget)
                .contentShape(Rectangle())
        }
        // `.button` + `.plain`, not `.borderlessButton`, which re-renders the label at its own size and colour.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("library.sort.help", bundle: .module))
    }
}
