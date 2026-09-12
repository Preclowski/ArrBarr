import SwiftUI

/// The one search, hosted once above the tabs.
///
/// Wraps a tab's content and owns everything search-shaped around it: the
/// field (macOS floating `SearchCapsule`; iOS `.searchable` + `SearchScopeBar`),
/// the takeover that replaces the content while a query is live, the shared
/// `SearchResultsSurface` and the person push it can trigger. Tabs render only
/// their own content and know nothing about search — the same host sits on the
/// Queue, Library and Upcoming tabs, so the search behaves identically on all
/// three because it IS the same view.
struct SearchHost<Content: View>: View {
    @Bindable var searchVM: SearchViewModel
    /// What the app already knows about that matches the query — the same on
    /// every tab (see `LocalHit.hits`).
    var localHits: [LocalHit]
    /// True when at least one arr can answer a lookup; gates the cold-start spinner.
    var searchAvailable: Bool
    /// iOS only: withdrawn while multi-select owns the toolbar.
    var enabled: Bool = true
    /// iOS only: the `.searchable` presentation, owned by the root so an empty
    /// field closes on a tab switch.
    var isPresented: Binding<Bool> = .constant(false)
    /// macOS only: the capsule's focus, owned by the root (⌘N aims at it).
    var focused: FocusState<Bool>.Binding? = nil
    var onSelectQueueItem: (QueueItem) -> Void = { _ in }
    let onSelectAddResult: (SearchResult) -> Void
    @ViewBuilder var content: () -> Content

    @EnvironmentObject private var configStore: ConfigStore
    @State private var personRef: PersonRef?
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
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, 16)
                    }
                }
                .background(Color(.systemBackground))
            } else {
                content()
            }
        }
        .modifier(SearchField(searchVM: searchVM, enabled: enabled, isPresented: isPresented))
        .personDestination($personRef)
        #else
        // The capsule floats at the bottom (Apple's recent search/Spotlight
        // direction). ZStack and not `safeAreaInset`: the inset modifier reacts
        // to any identity change in the parent tree — and the results re-render
        // on every keystroke — which re-mounts the TextField and drops focus
        // mid-typing. `ChatView` carries the long-form note.
        ZStack(alignment: .bottom) {
            if searchVM.isActive {
                SearchTakeoverView(searchVM: searchVM, searchAvailable: searchAvailable) {
                    surface
                }
            } else {
                content()
            }
            SearchCapsule(searchVM: searchVM, focused: focused ?? $fallbackFocus)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
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
