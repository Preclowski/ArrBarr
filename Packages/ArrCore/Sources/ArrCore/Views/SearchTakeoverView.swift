import SwiftUI

/// The header is pinned above the ScrollView: in search mode it stands in for the hidden tab bar.
struct SearchTakeoverView<Surface: View>: View {
    @Bindable var searchVM: SearchViewModel
    /// Gates the cold-start spinner: with nothing configured there is nothing to wait for.
    let searchAvailable: Bool
    @ViewBuilder var surface: () -> Surface

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    surface()
                    // With rows up this spinner is below the fold; `lookupReloadDim` covers that case.
                    if searchAvailable, searchVM.isSearching, !searchVM.hasResults {
                        loadingIndicator
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.bottom, 58)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: .infinity)
    }

    /// Clearing the query is what ends the takeover; the scope reset rides along in `onQueryChange`.
    private var header: some View {
        HStack(spacing: 6) {
            FloatingBackButton { searchVM.query = "" }
            Text("search.searching.header", bundle: .module)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var loadingIndicator: some View {
        LoadingStateView()
    }
}
