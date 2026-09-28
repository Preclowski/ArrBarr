import SwiftUI

/// The macOS floating search bar for both tabs. The spinner is inline because a loader
/// at the bottom of the list sits below the fold once results render.
struct SearchCapsule: View {
    @Bindable var searchVM: SearchViewModel
    var focused: FocusState<Bool>.Binding
    @EnvironmentObject var configStore: ConfigStore

    private var searchAvailable: Bool {
        QueueItem.Source.allCases.contains { configStore.config(for: $0.serviceKind).isVisible }
    }

    var body: some View {
        HStack(spacing: 8) {
            SearchFieldLeadingIcon(
                spinning: searchAvailable && searchVM.isSearching && searchVM.isActive)
            TextField("", text: $searchVM.query, prompt:
                Text("search.global.prompt", bundle: .module)
            )
            .scaledFont(size: 14)
            .textFieldStyle(.plain)
            .focused(focused)
            if searchVM.isActive && searchAvailable {
                scopeMenu
            }
            if !searchVM.query.isEmpty {
                Button { searchVM.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("queue.clearFilter.button", bundle: .module))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: searchVM.isActive)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Capsule())
        .onTapGesture { focused.wrappedValue = true }
        // Inverted so the input stops reading as more chrome.
        .glassyFloatingBar(focused: focused.wrappedValue, inverted: true)
    }

    /// Tinted while anything narrows the search, so a stuck narrow search is visible.
    /// `.menuStyle(.button)` + `.buttonStyle(.plain)` is the one combination that renders a custom label faithfully.
    private var scopeMenu: some View {
        let scope = searchVM.scope
        let libraryOnly = searchVM.libraryOnly
        return Menu {
            ForEach(SearchScope.available(for: configStore)) { s in
                Button { searchVM.scope = s } label: {
                    Label {
                        Text(LocalizedStringKey(s.labelKey), bundle: .module)
                    } icon: {
                        Image(systemName: s == scope ? "checkmark" : s.symbol)
                    }
                }
            }
            Divider()
            Button { searchVM.libraryOnly.toggle() } label: {
                Label {
                    Text("search.libraryOnly.toggle", bundle: .module)
                } icon: {
                    Image(systemName: libraryOnly ? "checkmark" : "books.vertical")
                }
            }
        } label: {
            Image(systemName: libraryOnly ? "books.vertical.fill" : scope.symbol)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(scope == .all && !libraryOnly
                                 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("search.scope.help", bundle: .module))
    }
}
