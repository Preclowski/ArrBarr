import SwiftUI
import SwiftData

/// "Add to list" menu + watched toggle, shared by the detail view and
/// context menus. All mutations go through here.
struct AddToListMenu: View {
    let item: MediaItem
    @Environment(\.modelContext) private var context
    @Query(sort: \WatchList.createdAt) private var lists: [WatchList]
    @State private var newListPrompt = false
    @State private var newListName = ""

    var body: some View {
        Menu {
            ForEach(lists) { list in
                Button {
                    toggle(in: list)
                } label: {
                    if isMember(of: list) {
                        Label(list.name, systemImage: "checkmark")
                    } else {
                        Text(list.name)
                    }
                }
            }
            if !lists.isEmpty { Divider() }
            Button { newListPrompt = true } label: { Text("New List…", bundle: .module) }
        } label: {
            Label { Text("Add to List", bundle: .module) } icon: {
                Image(systemName: memberOfAnything ? "text.badge.checkmark" : "plus")
            }
        }
        .alert(Text("New List", bundle: .module), isPresented: $newListPrompt) {
            TextField(text: $newListName) { Text("Name", bundle: .module) }
            Button { createListAndAdd() } label: { Text("Create", bundle: .module) }
            Button(role: .cancel) { newListName = "" } label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("The title will be added to the new list.", bundle: .module)
        }
    }

    private var memberOfAnything: Bool {
        guard let saved = Library.existingTitle(for: item, in: context) else { return false }
        return !saved.lists.isEmpty
    }

    private func isMember(of list: WatchList) -> Bool {
        guard let saved = Library.existingTitle(for: item, in: context) else { return false }
        return saved.lists.contains { $0.persistentModelID == list.persistentModelID }
    }

    private func toggle(in list: WatchList) {
        let saved = Library.savedTitle(for: item, in: context)
        if let idx = saved.lists.firstIndex(where: { $0.persistentModelID == list.persistentModelID }) {
            saved.lists.remove(at: idx)
            Library.pruneIfOrphaned(saved, in: context)
        } else {
            saved.lists.append(list)
        }
        try? context.save()
    }

    private func createListAndAdd() {
        let name = newListName.trimmingCharacters(in: .whitespaces)
        newListName = ""
        guard !name.isEmpty else { return }
        let list = WatchList(name: name)
        context.insert(list)
        let saved = Library.savedTitle(for: item, in: context)
        saved.lists.append(list)
        try? context.save()
    }
}

struct WatchedToggle: View {
    let item: MediaItem
    /// Icon alone, with the words in a tooltip — for the detail hero, where
    /// "Mark Watched" was the widest button on the cover and the check says
    /// it anyway.
    var compact = false
    @Environment(\.modelContext) private var context

    var body: some View {
        let watched = Library.existingTitle(for: item, in: context)?.watchedAt != nil
        Button {
            let saved = Library.savedTitle(for: item, in: context)
            saved.watchedAt = saved.watchedAt == nil ? .now : nil
            Library.pruneIfOrphaned(saved, in: context)
            try? context.save()
        } label: {
            if compact {
                Image(systemName: watched ? "checkmark.circle.fill" : "checkmark.circle")
            } else {
                Label {
                    watched ? Text("Watched", bundle: .module) : Text("Mark Watched", bundle: .module)
                } icon: {
                    Image(systemName: watched ? "checkmark.circle.fill" : "checkmark.circle")
                }
            }
        }
        .help(watched
              ? Text("Watched", bundle: .module)
              : Text("Mark Watched", bundle: .module))
    }
}
