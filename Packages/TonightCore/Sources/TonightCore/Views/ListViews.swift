import SwiftUI
import SwiftData

/// Shared multi-select scaffolding for the library grids: a Select/Done
/// toolbar toggle, and a floating action bar for the current selection.
private struct LibrarySelection: ViewModifier {
    let items: [MediaItem]
    /// The page's own name — what a deck dealt from it is called in the Quiz.
    let title: String
    /// The collection's layout — the Select/Done toggle only makes sense for
    /// posters; the list layout selects rows natively.
    @ObservedObject var options: MediaCollectionOptions
    @Binding var selecting: Bool
    @Binding var selection: Set<String>
    /// Extra destructive action for the current grid and its menu label
    /// ("Remove from List" / "Mark Unwatched").
    var removeLabel: LocalizedStringKey = "Remove from List"
    var remove: (([MediaItem]) -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.openInQuiz) private var openInQuiz
    @Query(sort: \WatchList.createdAt) private var lists: [WatchList]

    func body(content: Content) -> some View {
        content
            // Select/Done lives in the page, not in the window toolbar: the
            // toolbar stays empty on every page (see `WindowChrome`), and a
            // page that changes what it holds crashes SwiftUI in
            // `updateToolbarIfNeeded`.
            .safeAreaInset(edge: .top) {
                HStack(spacing: 12) {
                    Spacer()
                    QuizThisControl(options: options, items: items, name: title)
                    CollectionSortMenu(options: options)
                    MediaLayoutPicker(options: options)
                    if options.layout == .posters {
                        Button {
                            selecting.toggle()
                            if !selecting { selection.removeAll() }
                        } label: {
                            selecting ? Text("Done", bundle: .module) : Text("Select", bundle: .module)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
            }
            .safeAreaInset(edge: .bottom) {
                if !selection.isEmpty {
                    actionBar
                }
            }
            .onChange(of: options.layout) { _, _ in
                selecting = false
                selection.removeAll()
            }
    }

    private var selectedItems: [MediaItem] {
        items.filter { selection.contains($0.id) }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text(String(format: String(localized: "%d selected", bundle: .module), selection.count))
                .font(.callout.weight(.semibold))
            Spacer()
            // The selection is a collection too — swipe through just these.
            Button {
                let picked = selectedItems
                done()
                openInQuiz(picked, named: title)
            } label: {
                Label { Text("Open in Quiz", bundle: .module) } icon: {
                    Image(systemName: "rectangle.stack")
                }
            }
            Button {
                for item in selectedItems {
                    let saved = Library.savedTitle(for: item, in: context)
                    if saved.watchedAt == nil { saved.watchedAt = .now }
                }
                try? context.save()
                done()
            } label: {
                Label { Text("Mark Watched", bundle: .module) } icon: {
                    Image(systemName: "checkmark.circle")
                }
            }
            Menu {
                ForEach(lists) { list in
                    Button(list.name) {
                        for item in selectedItems {
                            let saved = Library.savedTitle(for: item, in: context)
                            if !saved.lists.contains(where: { $0.persistentModelID == list.persistentModelID }) {
                                saved.lists.append(list)
                            }
                        }
                        try? context.save()
                        done()
                    }
                }
            } label: {
                Label { Text("Add to List", bundle: .module) } icon: {
                    Image(systemName: "plus")
                }
            }
            .fixedSize()
            if let remove {
                Button(role: .destructive) {
                    remove(selectedItems)
                    done()
                } label: {
                    Label { Text(removeLabel, bundle: .module) } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    private func done() {
        selection.removeAll()
        selecting = false
    }
}

/// A user list rendered as a poster grid.
struct WatchListView: View {
    /// All user lists share one layout/column setup — switching to the list
    /// layout in one of them is a preference, not a per-list quirk.
    static let collection = MediaCollectionSpec.lists

    let list: WatchList
    @Environment(\.modelContext) private var context
    @State private var selecting = false
    @State private var selection = Set<String>()

    var body: some View {
        let items = list.titles
            .sorted { $0.addedAt > $1.addedAt }
            .map(\.mediaItem)
        MediaCollectionView(Self.collection, items: items,
                            selection: $selection, selectionActive: selecting)
        .overlay {
            if items.isEmpty {
                QuietMessage(systemImage: "list.and.film",
                             title: String(localized: "Empty list", bundle: .module),
                             subtitle: String(localized: "Add titles from any poster's detail page.", bundle: .module))
            }
        }
        .modifier(LibrarySelection(items: items, title: list.name,
                                   options: MediaCollectionOptions.shared(Self.collection),
                                   selecting: $selecting, selection: $selection,
                                   remove: { removeFromList($0) }))
    }

    private func removeFromList(_ items: [MediaItem]) {
        for item in items {
            guard let saved = Library.existingTitle(for: item, in: context) else { continue }
            saved.lists.removeAll { $0.persistentModelID == list.persistentModelID }
            Library.pruneIfOrphaned(saved, in: context)
        }
        try? context.save()
    }
}

struct WatchedView: View {
    static let collection = MediaCollectionSpec.watched

    @Query(filter: #Predicate<SavedTitle> { $0.watchedAt != nil },
           sort: \SavedTitle.watchedAt, order: .reverse)
    private var titles: [SavedTitle]
    @Environment(\.modelContext) private var context
    @State private var selecting = false
    @State private var selection = Set<String>()

    var body: some View {
        let items = titles.map(\.mediaItem)
        MediaCollectionView(Self.collection, items: items,
                            selection: $selection, selectionActive: selecting)
        .overlay {
            if items.isEmpty {
                QuietMessage(systemImage: "checkmark.circle",
                             title: String(localized: "Nothing watched yet", bundle: .module),
                             subtitle: String(localized: "Mark titles as watched from their detail page.", bundle: .module))
            }
        }
        .modifier(LibrarySelection(items: items,
                                   title: String(localized: "Watched", bundle: .module),
                                   options: MediaCollectionOptions.shared(Self.collection),
                                   selecting: $selecting, selection: $selection,
                                   removeLabel: "Mark Unwatched",
                                   remove: { markUnwatched($0) }))
    }

    /// In the Watched grid "remove" means "not watched after all".
    private func markUnwatched(_ items: [MediaItem]) {
        for item in items {
            guard let saved = Library.existingTitle(for: item, in: context) else { continue }
            saved.watchedAt = nil
            Library.pruneIfOrphaned(saved, in: context)
        }
        try? context.save()
    }
}
