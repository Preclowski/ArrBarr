import SwiftUI

/// Library tab — a browsable cover grid of everything already on the arrs.
/// Top strip: arr picker (menu-chip) + status filter chips + sort menu.
/// The library's chrome was sized for a 400pt popover and a mouse. On touch the
/// same numbers give 20pt hit areas — half Apple's 44pt minimum — so every
/// value the strip uses is forked rather than sprinkled with `#if` at each call.
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
/// Shows its content only when search is NOT open. `isSearching` is only
/// readable from inside the searchable content, hence the wrapper.
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
//
// File scope, not nested in `LibraryTabContent`: the filter bar is its own
// view now (see `LibraryFilterBar`) and both it and the grid speak in these
// terms.

private enum ViewMode: String { case grid, list }

private enum StatusFilter: CaseIterable {
    case all, missing, unmonitored

    /// Key for the view model's memoized filter / count caches.
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

    /// Key for the view model's per-axis sorted cache — see
    /// `LibraryViewModel.sorted(_:cacheKey:using:)`. Must stay 1:1 with
    /// `areInIncreasingOrder` ("title" is also the model's pre-warm key).
    var cacheKey: String { String(describing: self) }

    /// Every axis is defined ASCENDING; the view's one direction flag decides
    /// which way it is actually read. That is what lets the direction survive
    /// a change of axis — picking a different field re-sorts the same way, and
    /// only picking the field you are already on reverses it.
    ///
    /// Sorting is handed to the view model's memoized sort; it used to happen
    /// inline in `visibleEntries` on every body pass — ~20ms+ for a ~3k
    /// library on the localized title axis.
    var areInIncreasingOrder: (LibraryEntry, LibraryEntry) -> Bool {
        switch self {
        case .title:
            return LibraryViewModel.titleAscending
        case .releaseDate:
            // Undated entries sort as oldest, so they gather at one end
            // instead of scattering. Title breaks ties, always ascending.
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

    /// Brand names (IMDb/TMDB) render verbatim; the rest localize.
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

    /// SF Symbol for the menu row.
    ///
    /// Plain `Image(systemName:)` and nothing else: a SwiftUI menu row takes
    /// its icon from an actual `Image`, and the brand marks this used to draw
    /// (a pre-sized `NSImage` wrapped in a view) were silently dropped — the
    /// rows ended up with no icons at all. Brand marks live in the rating
    /// pills anyway; a menu is a monochrome context.
    ///
    /// `.rating` is whichever single score the source ships, so it carries a
    /// plain star: Sonarr's is TVDB's, Lidarr's its metadata provider's.
    func symbolName(for source: QueueItem.Source) -> String {
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

    /// Radarr exposes IMDb and TMDB as two separate sort axes (mirroring its
    /// own UI); Sonarr and Lidarr each ship one score, so both get `.rating`;
    /// Whisparr ships none. Lidarr has no release date either — that belongs
    /// to an artist's albums, not the artist — but every arr dates what it
    /// added, so `.dateAdded` is offered everywhere.
    static func available(for source: QueueItem.Source) -> [SortMode] {
        switch source {
        case .radarr: return [.title, .releaseDate, .dateAdded, .size, .imdb, .tmdb]
        case .sonarr: return [.title, .releaseDate, .dateAdded, .size, .rating]
        case .whisparr: return [.title, .releaseDate, .dateAdded, .size]
        case .lidarr: return [.title, .dateAdded, .size, .rating]
        }
    }
}

/// The Library tab's content: the browsing strip and the cover grid. Search is
/// not this view's business — `SearchHost` wraps it above the tabs.
struct LibraryTabContent: View {
    var viewModel: LibraryViewModel
    @EnvironmentObject var configStore: ConfigStore

    /// Which arr's library is on screen. Defaults to the first configured
    /// arr on appear; not persisted (the popover session is short-lived,
    /// same as the queue's scope).
    @State private var source: QueueItem.Source = .radarr
    @State private var sourceResolved = false
    @State private var statusFilter: StatusFilter = .all
    @State private var sort: SortMode = .title
    /// Ascending or descending, for whichever axis is selected. Deliberately
    /// NOT reset when the axis changes: switching fields keeps the direction
    /// you are reading in, and only picking the selected field again flips it.
    @State private var sortDescending = false
    /// Grid (covers) vs list (compact rows). Persisted — a layout preference,
    /// not per-session state like the filters above.
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
        // "Missing" is everything monitored that isn't fully on disk —
        // including not-yet-available titles (their chip explains why).
        case .missing: return entry.state == .missing || entry.state == .partial || entry.state == .notAvailable
        case .unmonitored: return entry.state == .unmonitored
        }
    }

    /// One count per filter, each memoized on the view model — the bar takes
    /// them as a plain value so it doesn't reach into the model itself.
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
        // Sort FIRST, through the view model's memoized per-axis cache —
        // filtering a pre-sorted list preserves order, and the filters are
        // the cheap half (sub-ms even at ~3k entries; the localized title
        // sort was the ~20ms-per-body-pass hitch felt on tab entry).
        // The direction is part of the key: the same axis read the other way
        // is a different order, and serving the cached one would ignore the tap.
        // Title-ascending must spell out to `LibraryViewModel.defaultSortCacheKey`
        // — that is the order the projection is pre-warmed in.
        let axisKey = "\(sort.cacheKey)|\(sortDescending ? "desc" : "asc")"
        let ascending = sort.areInIncreasingOrder
        let comparator: (LibraryEntry, LibraryEntry) -> Bool = sortDescending
            ? { ascending($1, $0) }
            : ascending
        let sorted = viewModel.sorted(source, cacheKey: axisKey, using: comparator)
        // Memoized too: `surface` re-runs whenever anything around the grid
        // does, and re-filtering ~3k records copies the whole array each time.
        return viewModel.visible(source, cacheKey: "\(axisKey)|\(statusFilter.cacheKey)",
                                 from: sorted) { matches($0, filter: statusFilter) }
    }

    var body: some View {
        surface
        .onAppear {
            // The default `.radarr` may not be configured — snap to the first
            // arr that is, once. (Re-running on every appear would fight a
            // manual pick.)
            if !sourceResolved {
                sourceResolved = true
                if let first = availableSources.first, !availableSources.contains(source) {
                    source = first
                }
            }
            Task { await load() }
        }
        .onChange(of: source) { _, _ in
            // A sort axis the new arr doesn't offer (IMDb on Sonarr) snaps
            // back to the default rather than silently sorting on nils.
            // Direction survives the axis reset, same as a manual switch.
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
                // Keep the last row clear of the floating capsule.
                .padding(.bottom, 58)
            }
            // Switching tabs tears this view down (the host swaps tab content
            // rather than keeping it mounted), so the position is parked on the
            // view model, which outlives it, and restored on the way back.
            .scrollPosition(id: gridAnchor, anchor: .top)
            .scrollBounceBehavior(.basedOnSize)
            // Content blurs softly under the floating glass chrome instead of
            // being cut off by it — same treatment as the queue.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .frame(maxHeight: .infinity)
        }
    }

    /// Top-most visible tile, parked on the view model. Hand-rolled rather
    /// than `@State` + sync: the scroll view writes this on every frame of a
    /// drag, and the model stores it `@ObservationIgnored` so those writes
    /// invalidate nothing.
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

    /// Which of the grid's states is on screen.
    private enum Phase: Equatable { case loading, failed, empty, content }

    private func phase(_ entries: [LibraryEntry]) -> Phase {
        if allEntries.isEmpty {
            if viewModel.loadFailed.contains(source) { return .failed }
            // A source that was never projected counts as loading too: the
            // frame between `onAppear` and `loadIfNeeded` raising its flag
            // used to flash the "empty library" state.
            if viewModel.entries[source] == nil || viewModel.loading.contains(source) { return .loading }
        }
        return entries.isEmpty ? .empty : .content
    }

    /// Browsing strip over the grid. On iOS the strip steps aside while the
    /// system search field is open (`LibraryFilterStrip`); on macOS the host's
    /// takeover replaces this whole view, strip included.
    ///
    /// The states swap without a transition. They used to cross-fade on a
    /// `.id(phase)`, which re-identified the whole grid: re-entering the tab
    /// with the library already cached still faded and slid the covers in, for
    /// content that was there the entire time.
    private var surface: some View {
        let entries = visibleEntries
        let phase = phase(entries)
        return gridOrState(entries, phase: phase)
            // Strip in the safe area: the covers scroll under it (and under
            // the tab bar above it) instead of starting below a hard line.
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
    /// Lidarr artist images are square (MusicBrainz/fanart covers), the other
    /// arrs ship 2:3 movie/series posters. Forcing 2:3 on Lidarr letterboxed
    /// every cover and blew the grid rows apart.
    var posterAspect: CGFloat {
        source == .lidarr ? 1 : 2.0 / 3.0
    }

    var isMonitored: Bool { state != .unmonitored }


    /// Localized availability/run label — shared mapping with the movie
    /// detail's existing-file banner (see `ArrReleaseStatusLabel`).
    func releaseStatusText(locale: Locale) -> String? {
        ArrReleaseStatusLabel.text(releaseStatus, locale: locale)
    }

    /// `includeYear: false` for the list row, whose title line already
    /// carries the year — repeating it in the meta line read as a stutter.
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

    /// One status word (or the x/y count for partially-downloaded series /
    /// artists). Drives the tooltip's Status line; the chip renders the same
    /// mapping via `MediaStateChip`.
    func statusText(locale: Locale) -> String {
        state.statusText(have: fileCount, total: totalCount, locale: locale)
    }

    var sizeText: String? {
        sizeOnDisk > 0 ? ByteCountFormatter.string(fromByteCount: sizeOnDisk, countStyle: .file) : nil
    }

    /// Tap routes through `DetailRequest.open` so the arr's full record opens
    /// in the same DetailView the queue rows use (Lidarr → the artist surface).
    func openDetail() {
        DetailRequest.open(source: source, arrId: arrId, title: title,
                           posterURL: posterURL, posterRequiresAuth: posterRequiresAuth)
    }
}

// MARK: - Tile

/// One cover in the grid: poster (2:3, or square for Lidarr) with a status
/// dot, title line, meta line.
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
                        // `.icon`, not `.card`: the grid is 104–160 pt wide, so
                        // 288 px covers it at @2x, and the icon copy is already
                        // on disk for every indexed title. Asking for `.card`
                        // pulled a 780 px poster per tile — one 180 kB file for
                        // a tile that displays ~200 px, and on a 3000-title
                        // library that alone was 400 MB of cache.
                        tier: .icon,
                        cornerRadius: Tokens.Radius.card,
                        fallbackSymbol: entry.source.symbol,
                        fill: true
                    )
                    .aspectRatio(entry.posterAspect, contentMode: .fit)
                }
                // Watched wedge with the monitored ribbon over it — the one
                // corner treatment every cover in the app shares.
                .posterMarks(watched: entry.watched, monitored: entry.isMonitored,
                             cornerRadius: Tokens.Radius.card, ribbonWidth: 10)
                Text(verbatim: entry.title)
                    .scaledFont(size: 11, weight: .semibold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                // Complete tiles keep the plain year · size caption; any
                // state that needs attention swaps it for the status chip.
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

/// Table-style row on the shared `PosterMetadataRow` chrome — the same
/// title-line + chevron + dot-joined metadata rhythm as the queue's search
/// and Upcoming rows. Segments: status · quality · file size.
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

    /// Status is a chip at the row's trailing edge now, so the metadata line
    /// opens with the file size — the fact you actually scan a library list
    /// for — and continues with episode/track counts and on-disk quality. The
    /// assigned profile leads the line as a chip (see `profileBadge`).
    private var metadataSegments: [String] {
        var segments: [String] = []
        if let size = entry.sizeText { segments.append(size) }
        // Series / artists show how much of the thing is on disk ("142/150");
        // skipped for partial, where the chip already IS that count.
        if entry.state != .partial, let total = entry.totalCount, total > 0 {
            segments.append("\(entry.fileCount ?? 0)/\(total)")
        }
        // Both axes on purpose: what's on disk AND what the arr aims for —
        // the quality here, the profile in the chip.
        if let quality = entry.fileQuality { segments.append(quality) }
        return segments
    }

    /// The assigned quality profile, drawn as the same `ProfileChip` the
    /// detail hero and this tab's own tooltip use. As a bare dot-joined
    /// segment it read as another quality string sitting next to the real
    /// one; the chip says "this is the target, not what's on disk".
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
            // Watched wedge only. No monitored ribbon on this row — the list
            // already dims an unmonitored entry wholesale, and two marks on a
            // 25pt thumbnail is one too many. The grid keeps both.
            posterWatched: entry.watched,
            title: rowTitle,
            metadataSegments: metadataSegments,
            onTap: { entry.openDetail() },
            metadataBadge: { profileBadge }
        ) {
            // Status sits at the row's trailing edge, so the chips line up in
            // a column down the list instead of starting at a different x on
            // every row (which is what pinning them to the title did). Its old
            // slot on the metadata line went to the file size.
            LibraryStatusChip(entry: entry)
        }
        .opacity(entry.state == .unmonitored ? 0.55 : 1)
        .libraryTooltip(entry: entry, apiKey: apiKey)
    }
}

// MARK: - Status chip

/// Outline chip carrying the entry's ownership state — same visual family
/// as the queue's `InQueueBadge` / `TagChip` (tinted text, tinted stroke,
/// chip-radius rectangle). Green Downloaded / orange x/y / red Missing /
/// muted Unmonitored.
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
    /// Shared 600 ms hover plumbing (see `HoverTooltip`), library content.
    func libraryTooltip(entry: LibraryEntry, apiKey: String?) -> some View {
        hoverTooltip { LibraryEntryTooltip(entry: entry, apiKey: apiKey) }
    }
}

/// The library counterpart of `QueueItemTooltip` — same 480 pt footprint,
/// same poster + header + info-grid + custom-format-chips anatomy, filled
/// with what the library record knows: status, on-disk quality, assigned
/// profile, size, file name, genres/runtime garnish.
private struct LibraryEntryTooltip: View {
    let entry: LibraryEntry
    let apiKey: String?
    @EnvironmentObject var configStore: ConfigStore
    /// Lazily-fetched `/moviefile` detail (Radarr/Whisparr): the list
    /// endpoint doesn't compute custom formats, release group or languages,
    /// so they arrive here ~200 ms after the tooltip opens. The clients
    /// keep a per-movie TTL cache, so re-hovers are free.
    @State private var fileDetails: ArrFile?
    /// Country of production — TMDB-only (see `CountryProvider`), fetched
    /// when the tooltip opens; the detail view then gets a cache hit.
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
            // Corner grammar: [context: release status][status: ownership].
            // Counts moved to the info grid; no bookmark (the hovered
            // row/tile already shows it).
            contextChip: entry.releaseStatusText(locale: configStore.currentLocale).map { AnyView(TagChip(text: $0)) },
            statusChip: AnyView(LibraryStatusChip(entry: entry))
        ) {
            // Detail-hero order: genres, rating pills, runtime · cert.
            if !entry.genres.isEmpty {
                GenreChips(genres: entry.genres)
            }
            // Detail-hero order: metadata line above the rating pills.
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TooltipRatingPills(chips: ratingChips)
            TooltipInfoGrid(lines: infoLines)
            TooltipOverview(text: entry.overview)
            // Quality-composition strip: assigned profile chip (same chip the
            // hero wears) leading the file's custom formats + score.
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
                fileDetails = try? await configStore.radarrClient.fetchMovieFile(movieId: entry.arrId)
            case .whisparr:
                fileDetails = try? await configStore.whisparrClient.fetchMovieFile(movieId: entry.arrId)
            case .sonarr, .lidarr:
                break
            }
        }
    }

    /// Fetched file detail wins over whatever the library list carried.
    private var formats: [String] {
        if let fetched = fileDetails?.customFormats, !fetched.isEmpty {
            return fetched.map(\.name)
        }
        return entry.customFormats
    }

    private var formatScore: Int {
        fileDetails?.customFormatScore ?? entry.customFormatScore
    }

    /// "119 min · R" — ratings render as pills above.
    private var subtitle: String {
        var parts: [String] = []
        // Same verbatim form the search rows use ("148 min").
        if let runtime = entry.runtime, runtime > 0 {
            parts.append("\(runtime) min")
        }
        if let cert = entry.certification, !cert.isEmpty {
            parts.append(cert)
        }
        // Country closes the line, as it does in the detail hero.
        parts.append(contentsOf: CountryProvider.displayNames(countries, locale: locale))
        return parts.joined(separator: " · ")
    }

    /// Factory-built pills, unlinked — the app-wide tooltip convention
    /// (hover chrome, not a click target; see SearchResultTooltip).
    private var ratingChips: [RatingChip] {
        var chips: [RatingChip] = []
        // Zero-hiding lives in the RatingChip factories — one rule, all
        // surfaces.
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
        // Episode/track tally — a dimensional fact, so it lives here with a
        // label, not as loose text crowding the title corner.
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
        // Release status renders as a title-row chip now, not a grid line.
        return lines
    }
}

// MARK: - Filter bar

/// The library's browsing strip: arr picker, status filters, layout toggle,
/// sort menu.
///
/// Its OWN view, not a computed property on `LibraryTabContent`. A computed
/// property shares the parent's identity and lifetime, so it re-ran whenever
/// anything about the parent changed — and this strip lives in the grid's
/// safe area, i.e. it was re-evaluated while the grid scrolled. As a struct
/// with value inputs, SwiftUI can skip it entirely when none of them moved.
/// `counts` is passed in already computed for the same reason.
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
            // Chips scroll horizontally — the localized labels ("Niemonitorowane")
            // overflow 400 pt and would otherwise wrap inside the capsules.
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
            // A `Picker`, not hand-built rows: the arr marks can't be trusted
            // to draw inside a menu row (that is what left this list with
            // generic film/tv glyphs that identified nothing), and the plain
            // alternative — a row per arr with no icon — is exactly what an
            // inline picker is. AppKit then owns the selection checkmark, so
            // the active arr is marked the way every other macOS menu marks
            // it. The trigger chip beside it still carries the real brand mark.
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
                // Trigger chip is an ordinary view, so the shared `ServiceIcon`
                // works here — it is the menu ROWS that can't keep artwork.
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
                        // `.secondary`, not `opacity`: over glass a faded copy
                        // of the label blends with the backdrop, where a real
                        // hierarchy level stays a solid, legible colour.
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, LibraryChrome.chipHPad)
            .padding(.vertical, LibraryChrome.chipVPad)
            // Flat: a filled capsule for the selected filter, nothing for the
            // rest. Glass here fought the covers behind it — the filter row is
            // a control strip, not floating chrome.
            .background {
                if selected { Capsule().fill(Color.primary.opacity(0.14)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// One button that flips grid ⇄ list. The glyph shows the layout you'd
    /// switch TO (like Finder's view toggles), the tooltip names it.
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

    /// SF Symbol or brand mark for one sort row — both monochrome, both
    /// tinted by the menu.
    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            ForEach(SortMode.available(for: source), id: \.self) { mode in
                Button {
                    // Picking the axis you are already on reverses it; picking
                    // a different one just changes the field.
                    if sort == mode {
                        sortDescending.toggle()
                    } else {
                        sort = mode
                    }
                } label: {
                    Label {
                        mode.label
                    } icon: {
                        // The active axis shows WHICH WAY it runs — selection
                        // mark and direction in one glyph, which is what tells
                        // the user a second tap did something.
                        Image(systemName: sort == mode
                              ? (sortDescending ? "arrow.down" : "arrow.up")
                              : mode.symbolName(for: source))
                    }
                    // Menu rows resolve `Label` at the container's label style,
                    // and inside a `Menu` that can come out title-only — which
                    // is why these rows drew their text and dropped every
                    // glyph. Stated per row, so nothing above can take it back.
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
        // `.button` + `.plain`, NOT `.borderlessButton`: the borderless style
        // re-renders the label with its own metrics, which is why this glyph
        // came out a different size and colour from the toggle beside it.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("library.sort.help", bundle: .module))
    }
}
