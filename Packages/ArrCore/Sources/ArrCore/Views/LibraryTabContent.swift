import SwiftUI

/// Library tab — a browsable cover grid of everything already on the arrs.
/// Top strip: arr picker (menu-chip) + status filter chips + sort menu.
/// Bottom: the same floating filter capsule the Queue tab uses, but purely
/// local (substring match over the cached library — no remote search).
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
    @State private var filterText = ""
    @FocusState private var filterFocused: Bool
    /// Grid (covers) vs list (compact rows). Persisted — a layout preference,
    /// not per-session state like the filters above.
    @AppStorage("libraryViewMode") private var viewModeRaw = ViewMode.grid.rawValue

    private enum ViewMode: String { case grid, list }

    private var viewMode: ViewMode {
        ViewMode(rawValue: viewModeRaw) ?? .grid
    }

    private enum StatusFilter: CaseIterable {
        case all, missing, unmonitored

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

        /// What the menu row draws. The rating axes ARE services, so they wear
        /// the service's own mark rather than a third identical star.
        ///
        /// The `-mono` assets, not the full-colour ones `RatingPill` uses: a
        /// menu row is a monochrome context (SF Symbols on the rows above),
        /// and the colour marks are filled artwork that can't be templated —
        /// IMDb's is a plaque with the letters drawn on top, so its silhouette
        /// is a solid blob. These are single-path silhouettes, so they tint
        /// themselves like every other glyph in the menu.
        enum Glyph {
            case symbol(String)
            /// Asset name in `ServiceIcons.xcassets`.
            case brand(String)
        }

        /// `.rating` is whichever single score the source ships, so its mark
        /// depends on the source: TVDB's for Sonarr, and a plain star for
        /// Lidarr, whose score is its metadata provider's and wears no mark
        /// we have.
        func glyph(for source: QueueItem.Source) -> Glyph {
            switch self {
            case .title: return .symbol("textformat")
            case .releaseDate: return .symbol("calendar")
            case .dateAdded: return .symbol("tray.and.arrow.down")
            case .size: return .symbol("internaldrive")
            case .imdb: return .brand("rating-imdb-mono")
            case .tmdb: return .brand("rating-tmdb-mono")
            case .rating: return source == .sonarr ? .brand("rating-tvdb-mono") : .symbol("star")
            }
        }
    }

    /// Radarr exposes IMDb and TMDB as two separate sort axes (mirroring its
    /// own UI); Sonarr and Lidarr each ship one score, so both get `.rating`;
    /// Whisparr ships none. Lidarr has no release date either — that belongs
    /// to an artist's albums, not the artist — but every arr dates what it
    /// added, so `.dateAdded` is offered everywhere.
    private var availableSorts: [SortMode] {
        switch source {
        case .radarr: return [.title, .releaseDate, .dateAdded, .size, .imdb, .tmdb]
        case .sonarr: return [.title, .releaseDate, .dateAdded, .size, .rating]
        case .whisparr: return [.title, .releaseDate, .dateAdded, .size]
        case .lidarr: return [.title, .dateAdded, .size, .rating]
        }
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

    private func count(for filter: StatusFilter) -> Int {
        allEntries.count { matches($0, filter: filter) }
    }

    private var visibleEntries: [LibraryEntry] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = allEntries.filter { matches($0, filter: statusFilter) }
        if !query.isEmpty {
            // Searches the entry's whole alias set, not its visible title:
            // accents folded ("leon" → "Léon"), and every translated name the
            // arr knows ("leon zawodowiec"). A raw compare on `title` hid both,
            // which reads as "you don't own it" — the one wrong answer this
            // app must never give.
            out = TitleMatch.indexedFilter(out, query: query, index: \.searchIndex)
        }
        switch sort {
        case .title:
            out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .releaseDate:
            // Newest first; undated entries sink to the end. Title breaks ties
            // ascending — hence the flipped operands on the second element.
            out.sort { ($0.releaseSortKey, $1.title) > ($1.releaseSortKey, $0.title) }
        case .dateAdded:
            // Most recently added first — "what did I just add" is the whole
            // point of this axis.
            out.sort { ($0.dateAdded ?? .distantPast, $1.title) > ($1.dateAdded ?? .distantPast, $0.title) }
        case .size:
            out.sort { $0.sizeOnDisk > $1.sizeOnDisk }
        case .imdb:
            out.sort { ($0.ratingImdb ?? -1) > ($1.ratingImdb ?? -1) }
        case .tmdb:
            out.sort { ($0.ratingTmdb ?? -1) > ($1.ratingTmdb ?? -1) }
        case .rating:
            out.sort { ($0.ratingArr ?? -1) > ($1.ratingArr ?? -1) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            topStrip
            ZStack(alignment: .bottom) {
                gridOrState
                filterBar
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
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
            if !availableSorts.contains(sort) { sort = .title }
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

    // MARK: - Top strip

    private var topStrip: some View {
        HStack(spacing: 6) {
            if availableSources.count > 1 {
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

    /// Arr picker — a rectangular menu-chip, deliberately NOT capsule-shaped
    /// so it reads as a different control class than the status chips beside
    /// it (mockup note: "pill na pillu" was the failure mode).
    /// `.menuStyle(.button)` + `.buttonStyle(.plain)` — the ONE combination
    /// that renders a custom SwiftUI label faithfully (same as the queue's
    /// scopeMenu). `.borderlessButton` flattens the label (native-size
    /// images, default menu font, dropped backgrounds — the oversized-
    /// "Radarr" bug), and a transparent Menu overlaid on a hand-drawn chip
    /// collapses to zero hit area.
    private var sourceMenu: some View {
        Menu {
            ForEach(availableSources, id: \.self) { s in
                Button { source = s } label: {
                    Label {
                        Text(verbatim: s.displayName)
                    } icon: {
                        // The arr's own mark rather than a generic film/tv
                        // glyph. These assets ship as templates, so they tint
                        // themselves and sit in the menu as monochrome as the
                        // SF Symbols they replace.
                        if s == source {
                            Image(systemName: "checkmark")
                        } else {
                            MenuBrandIcon(asset: s.brandIconName, template: true)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                // Trigger chip is an ordinary view, so the shared `ServiceIcon`
                // works here — only the menu ROWS need the pre-sized variant.
                ServiceIcon(source: source, size: 10)
                Text(verbatim: source.displayName)
                    .scaledFont(size: 11, weight: .semibold)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 8, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
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
        let count = count(for: filter)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { statusFilter = filter }
        } label: {
            HStack(spacing: 3) {
                Text(LocalizedStringKey(filter.labelKey), bundle: .module)
                    .scaledFont(size: 10, weight: selected ? .semibold : .medium)
                    .lineLimit(1)
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .scaledFont(size: 10, weight: .regular)
                        .monospacedDigit()
                        .opacity(0.65)
                }
            }
            .fixedSize()
            // Selected = the same soft primary tint the tab bar's selection
            // pill uses (see TabPillBackground) — an inverted fill washed out
            // under the popover's vibrancy and left the label unreadable.
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                if selected {
                    Capsule().fill(Color.primary.opacity(0.14))
                } else {
                    Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.75)
                }
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
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(viewMode == .grid ? "library.view.list" : "library.view.grid", bundle: .module))
        .accessibilityLabel(Text(viewMode == .grid ? "library.view.list" : "library.view.grid", bundle: .module))
    }

    /// SF Symbol or brand mark for one sort row — both monochrome, both
    /// tinted by the menu.
    @ViewBuilder
    private func sortGlyph(_ glyph: SortMode.Glyph) -> some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
        case .brand(let asset):
            MenuBrandIcon(asset: asset, template: true)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(availableSorts, id: \.self) { mode in
                Button { sort = mode } label: {
                    Label {
                        mode.label
                    } icon: {
                        // Selection still wins the slot — a row that only
                        // changed its glyph doesn't read as "this is the
                        // active sort".
                        if sort == mode {
                            Image(systemName: "checkmark")
                        } else {
                            sortGlyph(mode.glyph(for: source))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help(Text("library.sort.help", bundle: .module))
    }

    // MARK: - Grid

    @ViewBuilder
    private var gridOrState: some View {
        let entries = visibleEntries
        if allEntries.isEmpty, viewModel.loading.contains(source) {
            ScrollView {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("queue.loading.button", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        } else if allEntries.isEmpty, viewModel.loadFailed.contains(source) {
            emptyState(symbol: "exclamationmark.triangle", textKey: "library.error.title") {
                Button {
                    Task { await load(force: true) }
                } label: {
                    Text("common.retry.button", bundle: .module)
                }
                .modifier(GlassButtonStyle())
            }
        } else if entries.isEmpty {
            emptyState(symbol: "books.vertical", textKey: "library.empty.title") { EmptyView() }
        } else {
            ScrollView {
                Group {
                    if viewMode == .grid {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(entries) { entry in
                                LibraryTile(entry: entry, apiKey: apiKey(for: entry))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                LibraryListRow(entry: entry, apiKey: apiKey(for: entry))
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                // Keep the last row clear of the floating filter bar.
                .padding(.bottom, 58)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
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

    // MARK: - Bottom filter bar

    /// Same floating-capsule chrome as the Queue tab's bar, minus the scope
    /// menu — this field only narrows the cover grid, it never fires a
    /// remote search.
    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(.tertiary)
            TextField("", text: $filterText, prompt:
                Text("library.filter.prompt", bundle: .module)
            )
            .scaledFont(size: 14)
            .textFieldStyle(.plain)
            .focused($filterFocused)
            if !filterText.isEmpty {
                Button { filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("queue.clearFilter.button", bundle: .module))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Capsule())
        .onTapGesture { filterFocused = true }
        .glassyFloatingBar(focused: filterFocused)
        // Typeable the moment Library is on screen, whether the panel opened
        // on this tab or the user switched to it — same as Chat, and the same
        // end state the Queue reaches via `PopoverContentView`. (Queue's field
        // is driven from up there because it's the global search and ⌘N / the
        // Add intent aim at it too; this one and Chat's own theirs.)
        //
        // Hopped to the next main-actor turn because the field is not in the
        // responder chain during `onAppear`, and an assignment made before it
        // is there is silently dropped.
        .onAppear { Task { @MainActor in filterFocused = true } }
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

    /// Tap routes through DetailRequest so the arr's full record opens in the
    /// same DetailView the queue rows use (Lidarr → the artist surface).
    func openDetail() {
        if source == .lidarr {
            DetailRequest.post(DetailRequest.syntheticArtistItem(
                artistId: arrId,
                name: title,
                posterURL: posterURL,
                posterRequiresAuth: posterRequiresAuth
            ))
        } else {
            DetailRequest.post(DetailRequest.syntheticItem(
                source: source,
                entityId: arrId,
                title: title,
                posterURL: posterURL,
                posterRequiresAuth: posterRequiresAuth
            ))
        }
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
                        tier: .card,
                        cornerRadius: Tokens.Radius.card,
                        fallbackSymbol: entry.source.symbol,
                        fill: true
                    )
                    .aspectRatio(entry.posterAspect, contentMode: .fit)
                }
                .overlay(alignment: .topTrailing) {
                    // Monitored marker — the arr web UIs' bookmark language.
                    // White glyph + soft shadow so it reads over any poster
                    // art; unmonitored tiles are already dimmed wholesale.
                    if entry.isMonitored {
                        Image(systemName: "bookmark.fill")
                            .scaledFont(size: 9, weight: .medium)
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .padding(5)
                    }
                }
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
    private var profileBadge: AnyView? {
        entry.profileName.map { AnyView(ProfileChip(name: $0)) }
    }

    var body: some View {
        PosterMetadataRow(
            posterURL: entry.posterURL,
            posterAPIKey: apiKey,
            posterSize: CGSize(width: 38 * entry.posterAspect, height: 38),
            posterBlurred: configStore.shouldBlurPoster(for: entry.source),
            posterFallbackSymbol: entry.source.symbol,
            title: rowTitle,
            metadataSegments: metadataSegments,
            metadataBadge: profileBadge,
            onTap: { entry.openDetail() }
        ) {
            // Status sits at the row's trailing edge, so the chips line up in
            // a column down the list instead of starting at a different x on
            // every row (which is what pinning them to the title did). Its old
            // slot on the metadata line went to the file size.
            HStack(spacing: 6) {
                LibraryStatusChip(entry: entry)
                MonitorBookmark(isMonitored: entry.isMonitored)
            }
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
            TooltipRatingPills(chips: ratingChips)
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
            guard fileDetails == nil, entry.state == .complete else { return }
            switch entry.source {
            case .radarr:
                fileDetails = try? await RadarrClient(config: configStore.radarr).fetchMovieFile(movieId: entry.arrId)
            case .whisparr:
                fileDetails = try? await WhisparrClient(config: configStore.whisparr).fetchMovieFile(movieId: entry.arrId)
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
