import SwiftUI

/// One award's winners, newest first, optionally narrowed to a decade.
///
/// The catalog holds titles and years, not TMDB ids, so every winner is
/// matched against TMDB on the fly and the page fills in as the matches
/// land. What it draws is the ordinary library view — the same grid and
/// table as Movies and Series — with the award's decades as its own scope
/// control above it.
struct AwardWinnersView: View {
    let ref: AwardRef
    @EnvironmentObject private var config: TonightConfig

    /// winner year → the TMDB title it resolved to.
    @State private var resolved: [Int: MediaItem] = [:]
    @State private var decade: Int?
    @State private var loading = false

    var body: some View {
        Group {
            if let award = ref.award {
                content(award)
            } else {
                QuietMessage(systemImage: "trophy",
                             title: String(localized: "No award selected", bundle: .module),
                             subtitle: nil)
            }
        }
        .pushedPage()
        .task(id: taskKey) { await resolve() }
    }

    /// The winners that have a TMDB match, in the catalog's own order
    /// (newest first) — the collection's "Default Order".
    private func items(_ award: Award) -> [MediaItem] {
        award.winners(decade: decade).compactMap { resolved[$0.year] }
    }

    private func content(_ award: Award) -> some View {
        let items = items(award)
        return MediaCollectionView(.awarded, items: items, loading: loading)
            .overlay {
                if items.isEmpty && !loading {
                    QuietMessage(systemImage: "trophy",
                                 title: String(localized: "Nothing matches", bundle: .module),
                                 subtitle: nil)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { header(award) }
    }

    private func header(_ award: Award) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                BackButton()
                Label {
                    Text(award.displayName)
                } icon: {
                    Image(systemName: award.symbol)
                }
                .font(.headline)
                Text(award.displayCategory)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if loading { ProgressView().controlSize(.small) }

                Spacer(minLength: 0)

                QuizThisControl(.awarded, items: items(award),
                                name: award.displayName)
                CollectionSortMenu(.awarded)
                MediaLayoutPicker(.awarded)
            }
            // The decades are this page's scope — its equivalent of the
            // browse grid's filters, and the only thing there is to narrow.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: String(localized: "All Years", bundle: .module),
                               selected: decade == nil) { decade = nil }
                    ForEach(award.decades, id: \.self) { value in
                        FilterChip(title: Decade(start: value).displayName,
                                   selected: decade == value) {
                            decade = decade == value ? nil : value
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, pageChromeTop)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private var taskKey: String {
        "\(config.tmdbApiKey.hashValue)-\(ref.awardId)-\(decade ?? -1)"
    }

    /// Resolve only what the current scope shows, a few at a time — one
    /// search per winner, and the catalog runs to 75 entries.
    private func resolve() async {
        guard let award = ref.award else { return }
        let pending = award.winners(decade: decade).filter { resolved[$0.year] == nil }
        guard !pending.isEmpty else { return }
        loading = true
        defer { loading = false }
        let tmdb = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
        for chunk in stride(from: 0, to: pending.count, by: 6).map({
            Array(pending[$0..<min($0 + 6, pending.count)])
        }) {
            if Task.isCancelled { return }
            await withTaskGroup(of: (Int, MediaItem?).self) { group in
                for winner in chunk {
                    group.addTask {
                        (winner.year, try? await tmdb.movieMatch(title: winner.title, year: winner.year))
                    }
                }
                for await (year, item) in group {
                    if let item { resolved[year] = item }
                }
            }
        }
    }
}
