import SwiftUI

/// The one search, hosted above the tabs: field, takeover and results. Tabs know
/// nothing about search, so it behaves identically on every tab.
struct SearchHost<Content: View>: View {
    @Bindable var searchVM: SearchViewModel
    var localHits: [LocalHit]
    var searchAvailable: Bool
    /// iOS only: withdrawn while multi-select owns the toolbar.
    var enabled: Bool = true
    /// iOS only: owned by the root so an empty field closes on a tab switch.
    var isPresented: Binding<Bool> = .constant(false)
    /// macOS only: the capsule's focus, owned by the root (⌘F aims at it).
    var focused: FocusState<Bool>.Binding? = nil
    var onSelectQueueItem: (QueueItem) -> Void = { _ in }
    let onSelectAddResult: (SearchResult) -> Void
    @ViewBuilder var content: () -> Content

    @Environment(ConfigStore.self) private var configStore
    @State private var personRef: PersonRef?
    /// A tab's own full-popover surface (the Library's filters) has the field step aside.
    @State private var searchHidden = false
    @FocusState private var fallbackFocus: Bool

    var body: some View {
        #if os(iOS)
        VStack(spacing: 0) {
            SearchScopeBar(searchVM: searchVM, scopes: SearchScope.available(for: configStore))
            if searchVM.isActive {
                ScrollView {
                    surface
                        .padding(.vertical, 8)
                    if searchAvailable, searchVM.isSearching, !searchVM.hasResults {
                        LoadingStateView(label: nil)
                            .padding(.vertical, 16)
                    }
                }
                .background(Color(.systemBackground))
            } else {
                content()
            }
        }
        .modifier(SearchField(searchVM: searchVM, enabled: enabled && !searchHidden, isPresented: isPresented))
        .onPreferenceChange(TabTakeoverKey.self) { searchHidden = $0 }
        .personDestination($personRef)
        #else
        // ZStack, not `safeAreaInset`: the inset re-mounts the TextField on every
        // keystroke's re-render and drops focus.
        ZStack(alignment: .bottom) {
            if searchVM.isActive {
                SearchTakeoverView(searchVM: searchVM, searchAvailable: searchAvailable) {
                    surface
                }
            } else {
                content()
            }
            if !searchHidden {
                SearchCapsule(searchVM: searchVM, focused: focused ?? $fallbackFocus)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: searchHidden)
        .onPreferenceChange(TabTakeoverKey.self) { searchHidden = $0 }
        .personDestination($personRef)
        #endif
    }

    private var surface: some View {
        SearchResultsSurface(
            searchVM: searchVM,
            localHits: localHits,
            onSelectQueueItem: onSelectQueueItem,
            onSelectAddResult: onSelectAddResult,
            onSelectPerson: { personRef = $0 }
        )
    }
}

/// Set by a tab whose current surface takes the whole popover: no tab bar, no search.
struct TabTakeoverKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
