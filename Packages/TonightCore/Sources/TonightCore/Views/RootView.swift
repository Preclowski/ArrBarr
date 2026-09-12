import SwiftUI
import SwiftData
import AppKit
import ArrCore

public enum SidebarItem: Hashable {
    case home
    case quiz
    case movies
    case series
    case discover
    case inTheaters
    case watched
    case list(PersistentIdentifier)
}

/// App root: Apple-TV-style layout. One NavigationStack fills the whole
/// window so full-bleed heros can run edge to edge; the sidebar is a fixed
/// glass panel inset via the leading safe area, floating over that art.
/// The search field lives in the sidebar and takes over the content while
/// a query is active.
public struct RootView: View {
    @StateObject private var config = TonightConfig.shared
    /// MediaKit follows the config: a pasted TMDB key or a changed region
    /// rebuilds the provider graph without a relaunch.
    @StateObject private var media = MediaStack.shared
    @State private var selection: SidebarItem? = .home
    @State private var searchQuery = ""
    @State private var path = NavigationPath()
    @Query(sort: \WatchList.createdAt) private var lists: [WatchList]
    @Environment(\.modelContext) private var context

    @State private var newListPrompt = false
    @State private var newListName = ""
    /// Width of the sidebar column, as reported to the detail column.
    @State private var lane: CGFloat = 0
    /// The two halves the lane is derived from: the whole window and the
    /// detail column.
    @State private var totalWidth: CGFloat = 0
    @State private var detailWidth: CGFloat = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Survives leaving the Quiz tab, so the run resumes where it left off.
    @StateObject private var quiz = QuizSession()
    /// The page that dealt the current deck. A collection Quiz is entered
    /// FROM somewhere, so it needs a way back out to exactly there — dropping
    /// the user on Home after they swiped a list is losing their place.
    @State private var quizOrigin: QuizOrigin?
    /// Set while `returnFromQuiz` is putting the origin back, so the
    /// pop-to-root rule below does not undo the restored path one update later.
    @State private var restoringOrigin = false

    public init() {}

    public var body: some View {
        rootSplit
            .task { media.track(config) }
            .onChange(of: totalWidth) { _, _ in updateLane() }
            .onChange(of: detailWidth) { _, _ in updateLane() }
            // ArrBarr's settings are read, never shared live: the snapshot is
            // taken once per process. Coming back to this window is exactly
            // when the user may have just added a server over there, so it is
            // the one moment worth re-reading — otherwise a server added in
            // ArrBarr reads as "not configured" here until relaunch.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                ArrBarrProfile.refresh()
            }
    }

    private var rootSplit: some View {
        // A real split view, not a panel floated over the content: on this
        // OS the native sidebar already IS the glass slab with the artwork
        // behind it, and only the system places the traffic lights inside it
        // correctly.
        // The column has no toggle, so a collapse is unrecoverable: whenever
        // SwiftUI reports one, put it straight back.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            content
                .background { measure { detailWidth = $0 } }
        }
        // The lane is the window MINUS the detail column — the space the
        // sidebar takes, whatever it is made of.
        //
        // Two earlier attempts got this wrong and both showed up on Home,
        // whose hero spans the window and pads its copy back by the lane:
        // the detail column's `safeAreaInsets.leading` is a flat zero for a
        // real split-view column (title straight under the glass), and the
        // sidebar view's own width is a few points short of the column
        // (title flush against it). Subtracting is exact by construction and
        // survives the user dragging the divider.
        .background { measure { totalWidth = $0 } }
        .background(WindowChrome())
        .searchable(text: $searchQuery, placement: .sidebar,
                    prompt: Text("Movies, series…", bundle: .module))
        .environmentObject(config)
        .alert(Text("New List", bundle: .module), isPresented: $newListPrompt) {
            TextField(text: $newListName) { Text("Name", bundle: .module) }
            Button {
                let name = newListName.trimmingCharacters(in: .whitespaces)
                newListName = ""
                guard !name.isEmpty else { return }
                context.insert(WatchList(name: name))
                try? context.save()
            } label: {
                Text("Create", bundle: .module)
            }
            Button(role: .cancel) { newListName = "" } label: {
                Text("Cancel", bundle: .module)
            }
        }
    }

    /// Width reporter — `Color.clear` in a `GeometryReader`, the one shape
    /// that measures its container without changing it.
    private func measure(_ report: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { report(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, new in report(new) }
        }
    }

    /// The sidebar's lane, recomputed whenever either side of the split
    /// changes. Guarded against the hairline jitter a live divider drag
    /// produces, and against the first frame where the detail column has not
    /// been laid out yet and would report the whole window as its own.
    private var measuredLane: CGFloat {
        guard totalWidth > 0, detailWidth > 0 else { return lane }
        return max(0, totalWidth - detailWidth)
    }

    private func updateLane() {
        let width = measuredLane
        guard width > 0, abs(width - lane) > 0.5 else { return }
        lane = width
        // Pushed pages read the lane from here, not from this state: see
        // `SidebarLaneWidth`.
        SidebarLaneWidth.shared.width = width
    }

    /// Programmatic navigation, handed to every page. The environment's own
    /// default is a no-op, so a page that never gets this one silently does
    /// nothing when a table row is opened.
    private var openTitle: OpenTitleAction {
        OpenTitleAction { path.append($0) }
    }

    /// A library page's titles, dealt into the Quiz. Only the root owns both
    /// the session and the sidebar, so this is the one place a collection can
    /// become a deck AND land the user on the Quiz to swipe it.
    private var openInQuiz: OpenInQuizAction {
        OpenInQuizAction { items, name in
            guard !items.isEmpty else { return }
            quizOrigin = QuizOrigin(selection: selection, path: path)
            quiz.deal(items, from: name)
            if !path.isEmpty { path.removeLast(path.count) }
            selection = .quiz
        }
    }

    /// Where the user was standing when they dealt a deck into the Quiz.
    private struct QuizOrigin {
        let selection: SidebarItem?
        let path: NavigationPath
    }

    /// The Quiz's ✕: back to the page the deck came from, with whatever was
    /// pushed on top of it still there.
    private func returnFromQuiz(_ origin: QuizOrigin) {
        quizOrigin = nil
        // Only arm the guard when the selection actually changes — armed on a
        // no-op change it would never fire, and would swallow the pop-to-root
        // of the next sidebar click instead.
        if selection != origin.selection {
            restoringOrigin = true
            selection = origin.selection
        }
        path = origin.path
    }

    /// Everything a pushed page needs from the root. A destination that skips
    /// this renders under the sidebar and cannot navigate onwards.
    private func page<V: View>(_ view: V) -> some View {
        Page(content: view, openTitle: openTitle, openInQuiz: openInQuiz)
    }

    /// The page environment as a view of its own, because a
    /// `navigationDestination` closure is evaluated once and keeps what it
    /// captured: a `.environment(\.sidebarLane, lane)` written here handed
    /// every pushed page the zero the lane had on the first frame. Observing
    /// `SidebarLaneWidth` means the page follows the real width instead.
    private struct Page<Content: View>: View {
        let content: Content
        let openTitle: OpenTitleAction
        let openInQuiz: OpenInQuizAction
        @ObservedObject private var lane = SidebarLaneWidth.shared

        init(content: Content, openTitle: OpenTitleAction, openInQuiz: OpenInQuizAction) {
            self.content = content
            self.openTitle = openTitle
            self.openInQuiz = openInQuiz
        }

        var body: some View {
            content
                .environment(\.sidebarLane, lane.width)
                .environment(\.openTitle, openTitle)
                .environment(\.openInQuiz, openInQuiz)
        }
    }

    private var content: some View {
        // The window toolbar exists only for its height (it puts the traffic
        // lights inside the sidebar panel) and carries nothing at all, so the
        // detail column runs the full height of the window underneath it
        // instead of starting below an empty transparent strip. Pages that
        // need clearance at the top state their own padding.
        NavigationStack(path: $path) {
            // The root section needs the page environment too: Home's hero
            // spans the window and pads its copy by the lane, so without it
            // the title starts at x=0 — behind the sidebar.
            page(detailRoot)
                // Every destination re-states the page environment through
                // `page(_:)`: environment values set outside a NavigationStack
                // reach its root but not the pages it pushes.
                .navigationDestination(for: MediaItem.self) { item in
                    page(TitleDetailView(selection: TitleSelection(items: [item], index: 0)))
                }
                .navigationDestination(for: TitleSelection.self) { selection in
                    page(TitleDetailView(selection: selection))
                }
                .navigationDestination(for: PersonRef.self) { person in
                    page(PersonView(person: person))
                }
                .navigationDestination(for: PersonCreditsRef.self) { ref in
                    page(PersonCreditsView(ref: ref))
                }
                .navigationDestination(for: TMDBListRef.self) { list in
                    page(TMDBListView(list: list))
                }
                .navigationDestination(for: SearchCategoryRef.self) { ref in
                    page(SearchCategoryView(ref: ref))
                }
                .navigationDestination(for: GenreRef.self) { genre in
                    page(BrowseView(genre: genre))
                }
                .navigationDestination(for: DecadeRef.self) { decade in
                    page(BrowseView(decade: decade))
                }
                .navigationDestination(for: DiscoverSection.self) { section in
                    page(DiscoverSectionView(section: section))
                }
                .navigationDestination(for: QuizHistoryRef.self) { _ in
                    page(QuizHistoryView())
                }
                .navigationDestination(for: AwardRef.self) { award in
                    page(AwardWinnersView(ref: award))
                }
                .environment(\.openTitle, openTitle)
                .environment(\.openInQuiz, openInQuiz)
        }
        // The toolbar keeps its lane (it carries the traffic lights) but no
        // background of its own, so the artwork shows through the strip.
        // Pushed pages restate exactly the same thing in
        // `floatingBackButton()`: they do not inherit it, and a toolbar
        // config that CHANGES between pages crashes SwiftUI in
        // `updateToolbarIfNeeded`, so every page must declare it identically.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        .ignoresSafeArea(edges: .top)
        // The search page is the stack's ROOT — with a detail pushed on top
        // (say, a person page) it would change invisibly underneath. Pop to
        // root the moment a query starts, so results actually appear.
        .onChange(of: searchQuery) { _, newValue in
            let active = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
            if active && !path.isEmpty {
                path.removeLast(path.count)
            }
        }
        // …and the mirror rule: picking ANYTHING in the sidebar ends the
        // search. Otherwise a lingering query kept covering every section
        // with search results.
        // Picking a section also pops whatever was pushed on top of the old
        // one — otherwise the sidebar highlights Home while a title detail
        // still fills the column.
        .onChange(of: selection) { _, _ in
            searchQuery = ""
            // …except when the Quiz's ✕ is the one moving the selection: it
            // restores the page that dealt the deck, pushed detail and all.
            if restoringOrigin {
                restoringOrigin = false
                return
            }
            if !path.isEmpty { path.removeLast(path.count) }
        }
        // The detail column states its own floor. With the floor on the
        // whole window instead, widening the sidebar grew the WINDOW to keep
        // it satisfied — several screens wide — rather than shrinking the
        // column.
        .frame(minWidth: 460, maxWidth: .infinity,
               minHeight: 420, maxHeight: .infinity)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label { Text("Home", bundle: .module) } icon: { Image(systemName: "house") }
                    .tag(SidebarItem.home)
                Label { Text("Quiz", bundle: .module) } icon: { Image(systemName: "sparkles") }
                    .tag(SidebarItem.quiz)
                Label { Text("Movies", bundle: .module) } icon: { Image(systemName: "film") }
                    .tag(SidebarItem.movies)
                Label { Text("Series", bundle: .module) } icon: { Image(systemName: "tv") }
                    .tag(SidebarItem.series)
                Label { Text("Discover", bundle: .module) } icon: { Image(systemName: "square.grid.2x2") }
                    .tag(SidebarItem.discover)
                Label { Text("In Theaters", bundle: .module) } icon: { Image(systemName: "popcorn") }
                    .tag(SidebarItem.inTheaters)
            }
            Section(header: Text("My Library", bundle: .module)) {
                Label { Text("Watched", bundle: .module) } icon: { Image(systemName: "checkmark.circle") }
                    .tag(SidebarItem.watched)
            }
            Section(header: Text("My Lists", bundle: .module)) {
                ForEach(lists) { list in
                    Label { Text(list.name) } icon: { Image(systemName: list.symbol) }
                        .tag(SidebarItem.list(list.persistentModelID))
                        .contextMenu {
                            Button(role: .destructive) {
                                delete(list)
                            } label: {
                                Text("Delete List", bundle: .module)
                            }
                        }
                }
                Button {
                    newListPrompt = true
                } label: {
                    Label { Text("New List…", bundle: .module) } icon: { Image(systemName: "plus") }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            }
        // The column is nothing but the List: wrapping it in a VStack (for a
        // hand-rolled search field) stopped AppKit treating it as a sidebar,
        // which is what put the traffic lights in the window corner instead
        // of inside the sidebar's own inset panel.
        .listStyle(.sidebar)
        // No `min:` — dragging the divider below it was the other
        // unsatisfiable-constraint crash. The column can get narrow; it
        // can no longer take the app down or disappear entirely.
        .navigationSplitViewColumnWidth(min: 190, ideal: sidebarWidth, max: 320)
        // Re-clicking the already-selected row fires no selection change,
        // so ANY click in the sidebar list also ends an active search.
        .simultaneousGesture(TapGesture().onEnded { searchQuery = "" })
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private var detailRoot: some View {
        if !config.isConfigured {
            QuietMessage(
                systemImage: "key",
                title: String(localized: "Add your TMDB key", bundle: .module),
                subtitle: String(localized: "TonightBarr browses TMDB. Paste a free API key in Settings, or import it from ArrBarr.", bundle: .module),
                action: (String(localized: "Import from ArrBarr", bundle: .module),
                         { config.importFromArrBarr() })
            )
        } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsView(query: searchQuery)
        } else {
            switch selection ?? .home {
            case .home: HomeView()
            case .quiz:
                QuizView(session: quiz,
                         onClose: quizOrigin.map { origin in { returnFromQuiz(origin) } })
            case .movies: BrowseView(type: .movie)
            case .series: BrowseView(type: .tv)
            case .discover: DiscoverView()
            case .inTheaters: InTheatersView()
            case .watched: WatchedView()
            case .list(let id):
                if let list = lists.first(where: { $0.persistentModelID == id }) {
                    WatchListView(list: list)
                } else {
                    QuietMessage(systemImage: "list.and.film",
                                 title: String(localized: "No list selected", bundle: .module),
                                 subtitle: nil)
                }
            }
        }
    }

    private func delete(_ list: WatchList) {
        if case .list(let id) = selection, id == list.persistentModelID {
            selection = .home
        }
        let members = list.titles
        context.delete(list)
        for title in members { Library.pruneIfOrphaned(title, in: context) }
        try? context.save()
    }
}

