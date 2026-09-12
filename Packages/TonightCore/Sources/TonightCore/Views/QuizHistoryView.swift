import SwiftUI
import SwiftData

/// Navigation value for the Quiz history page.
public struct QuizHistoryRef: Hashable, Sendable {
    public init() {}
}

/// Everything swiped in the Quiz, shown through the library's own collection
/// view and its advanced-filter inspector. Read-only: the verdicts feed
/// nothing yet, this is just the log made visible.
struct QuizHistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \QuizVerdict.decidedAt, order: .reverse) private var verdicts: [QuizVerdict]

    @State private var filter = DiscoverFilter(type: .movie)
    @State private var verdictFilter: VerdictFilter = .all
    @State private var typeFilter: TypeFilter = .all
    @State private var confirmClear = false

    private enum VerdictFilter: String, CaseIterable, Identifiable {
        case all, liked, skipped

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return String(localized: "All", bundle: .module)
            case .liked: return String(localized: "Liked", bundle: .module)
            case .skipped: return String(localized: "Skipped", bundle: .module)
            }
        }
    }

    private enum TypeFilter: String, CaseIterable, Identifiable {
        case all, movies, series

        var id: String { rawValue }
        var mediaType: MediaType? {
            switch self {
            case .all: return nil
            case .movies: return .movie
            case .series: return .tv
            }
        }
        var title: String {
            switch self {
            case .all: return String(localized: "All", bundle: .module)
            case .movies: return String(localized: "Movies", bundle: .module)
            case .series: return String(localized: "Series", bundle: .module)
            }
        }
    }

    /// The log, filtered: the page's own splits first, then everything the
    /// shared filter inspector can say about a stored title.
    private var shown: [QuizVerdict] {
        verdicts.filter { verdict in
            switch verdictFilter {
            case .all: break
            case .liked: guard verdict.liked else { return false }
            case .skipped: guard !verdict.liked else { return false }
            }
            if let type = typeFilter.mediaType, verdict.mediaType != type { return false }
            return filter.matches(verdict.mediaItem)
        }
    }

    /// One row per title: a card swiped, undone and dealt again should not
    /// show up twice. The order is the collection view's business — the log's
    /// own, newest first, until the Sort menu says otherwise.
    private var items: [MediaItem] {
        var seen = Set<String>()
        return shown.map(\.mediaItem).filter { seen.insert($0.id).inserted }
    }

    /// Liked / skipped for the collection's Decision column — the newest
    /// verdict wins for a title swiped more than once.
    private func verdict(for item: MediaItem) -> Bool? {
        verdicts.first { $0.key == item.id }?.liked
    }

    var body: some View {
        collection
            .pushedPage()
            .confirmationDialog(Text("Clear Quiz History?", bundle: .module),
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button(role: .destructive) { clear() } label: {
                    Text("Clear", bundle: .module)
                }
                Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
            } message: {
                Text("This only deletes the log. Titles saved to Quiz Picks stay.", bundle: .module)
            }
    }

    private var collection: some View {
        MediaCollectionView(.quizHistory, items: items, verdict: verdict(for:))
            .overlay {
                if items.isEmpty {
                    QuietMessage(
                        systemImage: "clock.arrow.circlepath",
                        title: String(localized: "No swipes yet", bundle: .module),
                        subtitle: String(localized: "Cards you like or skip in the Quiz are logged here.", bundle: .module))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    // MARK: - Chrome

    /// The page's header strip, laid out like every other library page:
    /// under the traffic-light strip, back control included.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Back belongs in this row, not floating above it: over a header
                // strip it just stacks a second row of chrome on top of the page.
                BackButton()
                // The page names itself here: a `navigationTitle` would put the
                // name in the window toolbar, and a page that changes what that
                // toolbar holds crashes SwiftUI in `updateToolbarIfNeeded`.
                Text("Quiz History", bundle: .module)
                    .font(.headline)
                Text(String(format: String(localized: "%d titles", bundle: .module), items.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button { confirmClear = true } label: {
                    Text("Clear History", bundle: .module)
                }
                .disabled(verdicts.isEmpty)
                CollectionSortMenu(.quizHistory)
                MediaLayoutPicker(.quizHistory)
                FiltersControl(filter: $filter,
                               type: typeFilter.mediaType ?? .movie,
                               local: true,
                               showsGenres: typeFilter != .all,
                               extra: AnyView(pageFilters),
                               extraCount: pageFilterCount,
                               resultCount: items.count,
                               clearExtra: { clearPageFilters() })
            }
            ActiveFilterRow(filter: $filter,
                            type: typeFilter.mediaType ?? .movie,
                            extra: pageTokens,
                            clearExtra: { clearPageFilters() })
        }
        .padding(.horizontal, 28)
        .padding(.top, pageChromeTop)
        .padding(.bottom, 10)
        .background(.bar)
        .animation(.easeOut(duration: 0.18), value: activeCount)
    }

    /// The page's own splits, as tokens in the row under the header — so the
    /// log says "Liked · Movies" out loud rather than only inside the panel.
    private var pageTokens: [FilterToken] {
        var tokens: [FilterToken] = []
        if verdictFilter != .all {
            tokens.append(FilterToken(id: "verdict", title: verdictFilter.title) {
                verdictFilter = .all
            })
        }
        if typeFilter != .all {
            tokens.append(FilterToken(id: "media", title: typeFilter.title) {
                typeFilter = .all
            })
        }
        return tokens
    }

    private var pageFilterCount: Int {
        (verdictFilter == .all ? 0 : 1) + (typeFilter == .all ? 0 : 1)
    }

    private func clearPageFilters() {
        verdictFilter = .all
        typeFilter = .all
    }

    private var activeCount: Int { filter.activeCount + pageFilterCount }

    /// The two splits only this page has, shown at the top of the panel.
    private var pageFilters: some View {
        VStack(alignment: .leading, spacing: 22) {
            FilterSection("Media") {
                FlowLayout {
                    ForEach(TypeFilter.allCases) { option in
                        FilterChip(title: option.title, selected: typeFilter == option) {
                            typeFilter = option
                            // Genres belong to one type; the list behind them
                            // changes underfoot otherwise.
                            filter.genreIds = []
                            if let type = option.mediaType { filter.type = type }
                        }
                    }
                }
            }
            FilterSection("Decision") {
                FlowLayout {
                    ForEach(VerdictFilter.allCases) { option in
                        FilterChip(title: option.title, selected: verdictFilter == option) {
                            verdictFilter = option
                        }
                    }
                }
            }
        }
    }

    private func clear() {
        for verdict in verdicts { context.delete(verdict) }
        try? context.save()
    }
}
