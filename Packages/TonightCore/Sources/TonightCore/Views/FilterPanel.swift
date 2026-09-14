import SwiftUI
import ArrCore

// The filter surface: a popover hung off the Filters button, plus the row of
// tokens under the page header that says what is currently switched on.
//
// It used to be a 300pt column that pushed the grid aside and stayed open
// across visits. That cost was permanent and the value occasional: the common
// case is nought or one active filter, and the panel was 90% air. The popover
// costs nothing at rest, and the token row — not a numeral in a badge — is
// what keeps the state visible.

// MARK: - Flow layout

/// Wrapping row layout for chip groups — genres and services need as many
/// rows as they need, and a LazyVGrid would leave ragged gaps between chips
/// of different widths.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(into: CGFloat(0)) { $0 += $1.height }
            + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, x + size.width > width {
                rows.append(row)
                row = Row()
                x = 0
            }
            row.indices.append(index)
            row.height = max(row.height, size.height)
            x += size.width + spacing
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Section

/// One labelled block of the panel. Pages that add their own sections
/// (the Quiz log) build them from this, so they line up with the rest.
struct FilterSection<Content: View>: View {
    let key: LocalizedStringKey
    var value: String? = nil
    @ViewBuilder let content: Content

    init(_ key: LocalizedStringKey, value: String? = nil, @ViewBuilder content: () -> Content) {
        self.key = key
        self.value = value
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(key, bundle: .module)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                if let value {
                    Text(value)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
            content
        }
    }
}

// MARK: - Chips

/// A selectable pill. The one chip shape the filter panel uses.
struct FilterChip: View {
    let title: String
    var systemImage: String? = nil
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                if selected {
                    Capsule().fill(Color.accentColor)
                } else {
                    Capsule().fill(hovering ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
                }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0.25 : 0.06), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

/// One active filter, shown under the page header with a ✕ that clears it.
struct ActiveFilterChip: View {
    let title: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.caption.weight(.medium))
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.85), in: Capsule())
    }
}

// MARK: - Active filters

/// One thing that is switched on, and the way to switch it off. Pages with
/// splits of their own (the Quiz log's liked/skipped) hand theirs in, so the
/// row speaks for the whole page rather than for `DiscoverFilter` alone.
struct FilterToken: Identifiable {
    let id: String
    let title: String
    let clear: () -> Void

    init(id: String, title: String, clear: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.clear = clear
    }
}

/// The row of active filters under a page header. Nothing at all when
/// nothing is on — the chrome grows only when there is something to say.
///
/// This is what lets the panel be a popover: the state that used to need a
/// column standing open is legible here, and one click from gone.
struct ActiveFilterRow: View {
    @Binding var filter: DiscoverFilter
    let type: MediaType
    /// What the page itself is pinned to is its identity, not a filter the
    /// user switched on — it is named in the page title and never here.
    var preset: FilterPreset = .none
    var extra: [FilterToken] = []
    /// Cleared along with everything else — a page's own splits included.
    var clearExtra: (() -> Void)? = nil

    var body: some View {
        let tokens = extra + filterTokens
        if !tokens.isEmpty {
            HStack(spacing: 6) {
                FlowLayout {
                    ForEach(tokens) { token in
                        ActiveFilterChip(title: token.title, clear: token.clear)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    // The pin goes back and the scope stays: Clear All must
                    // not drag the page out of the decade or genre it is,
                    // nor out of the library the user is browsing.
                    filter = preset.applied(to: filter)
                    clearExtra?()
                } label: {
                    Text("Clear All", bundle: .module)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            }
        }
    }

    private var filterTokens: [FilterToken] {
        var tokens: [FilterToken] = []
        for genre in filter.genreIds.subtracting(preset.genreIds).sorted() {
            tokens.append(FilterToken(id: "genre-\(genre)",
                                      title: Genres.displayName(for: genre, type: type)) {
                filter.genreIds.remove(genre)
            })
        }
        if let years = yearSummary, !preset.ownsYears(of: filter) {
            tokens.append(FilterToken(id: "years", title: years) {
                filter.startYear = nil
                filter.endYear = nil
            })
        }
        if let rating = filter.minRating {
            let value = rating.formatted(.number.precision(.fractionLength(1)))
            tokens.append(FilterToken(id: "rating", title: "★ \(value)+") {
                filter.minRating = nil
            })
        }
        if let votes = filter.minVotes {
            tokens.append(FilterToken(id: "votes",
                                      title: String(format: String(localized: "%d votes+", bundle: .module), votes)) {
                filter.minVotes = nil
            })
        }
        if let runtime = filter.maxRuntime {
            tokens.append(FilterToken(id: "runtime", title: "≤ \(runtime) min") {
                filter.maxRuntime = nil
            })
        }
        for provider in filter.providerIds.sorted() {
            let name = StreamingProviders.name(for: provider) ?? "#\(provider)"
            tokens.append(FilterToken(id: "provider-\(provider)", title: name) {
                filter.providerIds.remove(provider)
            })
        }
        if let language = filter.language {
            tokens.append(FilterToken(id: "language",
                                      title: FilterLanguages.displayName(language)) {
                filter.language = nil
            })
        }
        return tokens
    }

    private var yearSummary: String? {
        switch (filter.startYear, filter.endYear) {
        case (nil, nil): return nil
        case let (start?, end?):
            if start == end { return String(start) }
            return end == start + 9 ? "\(String(start))s" : "\(String(start))–\(String(end))"
        case let (start?, nil): return "\(String(start))+"
        case let (nil, end?): return "≤ \(String(end))"
        }
    }
}

// MARK: - The control

/// The Filters button and the panel it opens. One control, so a page places
/// filtering with a single line and cannot get the two halves out of step.
struct FiltersControl: View {
    @Binding var filter: DiscoverFilter
    let type: MediaType
    /// A collection the app already holds (the Quiz log, a list) can answer
    /// genres, years and scores from its snapshot, but knows nothing about
    /// runtime, streaming services or original language — those sections are
    /// left out rather than shown dead.
    var local: Bool = false
    /// Genres belong to one media type; a page showing both at once has no
    /// sane list to offer.
    var showsGenres: Bool = true
    /// Filters that only make sense for the page that opened the panel —
    /// the Quiz log's liked/skipped and movies/series splits.
    var extra: AnyView? = nil
    /// How many of those are switched on, for the badge.
    var extraCount: Int = 0
    /// How many titles the page is currently showing — the footer's tally.
    let resultCount: Int
    var preset: FilterPreset = .none
    var clearExtra: (() -> Void)? = nil

    /// Transient by design. An open panel was remembered across launches and
    /// so was every filter in it; a filter you cannot see is how a browse
    /// page ends up looking broken.
    @State private var open = false

    private var count: Int { preset.userCount(in: filter) + extraCount }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("Filters", bundle: .module)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .glassControl(active: open || count > 0)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [.option, .command])
        .help(Text("Filters", bundle: .module))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FilterPanel(filter: $filter, type: type, local: local,
                        showsGenres: showsGenres, extra: extra,
                        resultCount: resultCount, preset: preset,
                        clearExtra: clearExtra)
        }
    }
}

// MARK: - The panel

/// The panel itself: what a title has to be, in the order these questions are
/// actually asked. Sort is not here — it is how the page is read, not what it
/// holds, and it lives in the header's own menu.
struct FilterPanel: View {
    @Binding var filter: DiscoverFilter
    let type: MediaType
    var local: Bool = false
    var showsGenres: Bool = true
    var extra: AnyView? = nil
    let resultCount: Int
    var preset: FilterPreset = .none
    var clearExtra: (() -> Void)? = nil

    /// The long tail: set once in a while, so it costs one click instead of
    /// a screenful of scrolling every time. Opens by itself when something
    /// inside it is on, so no filter can hide behind a collapsed group.
    @State private var showMore = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let extra { extra }
                    if showsGenres { genreSection }
                    yearSection
                    ratingSection
                    if !local { moreSection }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
        }
        .frame(width: 340)
        .frame(maxHeight: 560)
        .onAppear { showMore = hasMoreFilters }
    }

    // MARK: Footer

    /// Nothing to reset: what the panel holds is exactly the page's own pin.
    private var untouched: Bool { preset.userCount(in: filter) == 0 }

    private var footer: some View {
        HStack {
            Text(String(format: String(localized: "%d titles", bundle: .module), resultCount))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                filter = preset.applied(to: filter)
                clearExtra?()
            } label: {
                Text("Reset All", bundle: .module)
            }
            .buttonStyle(.plain)
            .foregroundStyle(untouched ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            .disabled(untouched)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: Sections

    private func section<Content: View>(_ key: LocalizedStringKey,
                                        value: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        FilterSection(key, value: value, content: content)
    }

    private var genreSection: some View {
        section("Genres", value: filter.genreIds.isEmpty ? nil : "\(filter.genreIds.count)") {
            FlowLayout {
                ForEach(Genres.list(for: type), id: \.id) { genre in
                    FilterChip(title: Genres.displayName(for: genre.id, type: type),
                               selected: filter.genreIds.contains(genre.id)) {
                        if filter.genreIds.contains(genre.id) {
                            filter.genreIds.remove(genre.id)
                        } else {
                            filter.genreIds.insert(genre.id)
                        }
                    }
                }
            }
        }
    }

    private var yearSection: some View {
        section("Years", value: yearSummary) {
            // Decades only. The pair of year menus that used to sit under
            // them was 127 rows deep, needed two decisions to say one thing,
            // and nobody browsing for something to watch tonight has an
            // opinion about 1974 in particular.
            FlowLayout {
                FilterChip(title: String(localized: "Any", bundle: .module),
                           selected: filter.startYear == nil && filter.endYear == nil) {
                    filter.startYear = nil
                    filter.endYear = nil
                }
                ForEach(decades, id: \.self) { decade in
                    FilterChip(title: "\(String(decade))s",
                               selected: filter.startYear == decade && filter.endYear == decade + 9) {
                        if filter.startYear == decade && filter.endYear == decade + 9 {
                            filter.startYear = nil
                            filter.endYear = nil
                        } else {
                            filter.startYear = decade
                            filter.endYear = decade + 9
                        }
                    }
                }
            }
        }
    }

    /// The score filter says whose score it is. TMDB is the only service that
    /// can answer at list time — a discover query is filtered by TMDB's own
    /// `vote_average`, and IMDb or Rotten Tomatoes arrive per title, one
    /// lookup at a time, long after the grid has been drawn. Naming the
    /// service is the honest version of a star with no owner.
    private var ratingSection: some View {
        FilterSection("Rating", value: filter.minRating.map {
            "\($0.formatted(.number.precision(.fractionLength(1))))+"
        }) {
            VStack(alignment: .leading, spacing: 6) {
                Slider(value: Binding(get: { filter.minRating ?? 0 },
                                      set: { filter.minRating = $0 < 0.1 ? nil : $0 }),
                       in: 0...9, step: 0.5)
                HStack(spacing: 5) {
                    BrandMark(name: "tmdb", height: 9)
                    Text("TMDB score — the only one a list can be filtered by", bundle: .module)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Votes, length, streaming and language: the filters set once a month,
    /// behind one disclosure instead of three screens of scrolling.
    private var moreSection: some View {
        DisclosureGroup(isExpanded: $showMore) {
            VStack(alignment: .leading, spacing: 20) {
                votesSection
                if type == .movie { runtimeSection }
                providerSection
                languageSection
            }
            .padding(.top, 12)
        } label: {
            Text("More Filters", bundle: .module)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
        }
    }

    private var votesSection: some View {
        section("Minimum votes", value: filter.minVotes.map { "\($0)+" }) {
            Slider(value: Binding(get: { Double(filter.minVotes ?? 0) },
                                  set: { filter.minVotes = $0 < 50 ? nil : Int($0) }),
                   in: 0...5000, step: 50)
        }
    }

    private var runtimeSection: some View {
        section("Length", value: filter.maxRuntime.map { "≤ \($0) min" }) {
            Slider(value: Binding(get: { Double(filter.maxRuntime ?? 240) },
                                  set: { filter.maxRuntime = $0 >= 239 ? nil : Int($0) }),
                   in: 60...240, step: 10)
        }
    }

    private var providerSection: some View {
        section("Streaming", value: filter.providerIds.isEmpty ? nil : "\(filter.providerIds.count)") {
            FlowLayout {
                ForEach(StreamingProviders.all, id: \.id) { provider in
                    FilterChip(title: provider.name,
                               selected: filter.providerIds.contains(provider.id)) {
                        if filter.providerIds.contains(provider.id) {
                            filter.providerIds.remove(provider.id)
                        } else {
                            filter.providerIds.insert(provider.id)
                        }
                    }
                }
            }
        }
    }

    private var languageSection: some View {
        section("Language") {
            FlowLayout {
                FilterChip(title: String(localized: "Any", bundle: .module),
                           selected: filter.language == nil) { filter.language = nil }
                ForEach(FilterLanguages.all, id: \.self) { code in
                    FilterChip(title: FilterLanguages.displayName(code),
                               selected: filter.language == code) {
                        filter.language = filter.language == code ? nil : code
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private var hasMoreFilters: Bool {
        filter.minVotes != nil || filter.maxRuntime != nil
            || !filter.providerIds.isEmpty || filter.language != nil
    }

    private var yearSummary: String? {
        switch (filter.startYear, filter.endYear) {
        case (nil, nil): return nil
        case let (start?, end?): return start == end ? String(start) : "\(String(start))–\(String(end))"
        case let (start?, nil): return "\(String(start))+"
        case let (nil, end?): return "≤ \(String(end))"
        }
    }

    private var currentYear: Int { Calendar.current.component(.year, from: .now) }

    private var decades: [Int] {
        stride(from: currentYear / 10 * 10, through: 1950, by: -10).map { $0 }
    }
}

// MARK: - Scope

/// "Only what I have" — the library scope, as the one thing people actually
/// flip: a checkbox.
///
/// It began as a drive-icon button covering two of three states, became a
/// three-way segmented control, and ends here. Three modes were more than the
/// question deserves: the interesting one is "hide what I do not own", and a
/// checkbox says that in the plainest control macOS has. The third state (a
/// shopping list of things NOT owned) stays in the model — `DiscoverFilter`
/// can still ask for it — but no longer costs a control on every page.
///
/// Remembered globally: whether you are browsing your own shelf is a frame of
/// mind that should follow you from Movies to Series to a genre page.
struct OwnedOnlyToggle: View {
    @Binding var presence: DiscoverFilter.LibraryPresence
    @EnvironmentObject private var externalLibrary: ExternalLibraryStore
    @AppStorage("browse.ownedOnly") private var stored = false

    var body: some View {
        Group {
            if externalLibrary.isAvailable {
                Toggle(isOn: Binding(get: { presence == .owned },
                                     set: { on in
                                         presence = on ? .owned : .all
                                         stored = on
                                     })) {
                    Text("Only what I have", bundle: .module)
                        .font(.callout)
                }
                .toggleStyle(.checkbox)
                .help(Text("Hide titles your media server doesn't have", bundle: .module))
            }
        }
        // Without a media server there is nothing to be "in": the control is
        // absent rather than disabled, and the scope is everything.
        .task(id: externalLibrary.isAvailable) {
            presence = externalLibrary.isAvailable && stored ? .owned : .all
        }
    }
}
