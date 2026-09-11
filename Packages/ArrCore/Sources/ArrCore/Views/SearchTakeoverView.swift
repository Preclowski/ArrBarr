import SwiftUI

/// The takeover host: while a query is live, search owns the window on BOTH
/// tabs. The header is pinned ABOVE the ScrollView so it stays stuck to the
/// top of the popover — in search mode it stands in for the hidden tab bar as
/// the top strip — instead of scrolling away with the results beneath it.
struct SearchTakeoverView<Surface: View>: View {
    @Bindable var searchVM: SearchViewModel
    /// True when at least one arr can answer. Gates the cold-start spinner:
    /// with nothing configured there is nothing to wait for.
    let searchAvailable: Bool
    @ViewBuilder var surface: () -> Surface

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    surface()
                    // Only while nothing is rendered yet. With rows up this
                    // spinner sits below the fold and the user sees no loading
                    // state at all on a re-search — that case is covered by
                    // `lookupReloadDim` inside the surface instead.
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

    /// Back chevron clears the query, which is what ends the takeover — the
    /// scope reset rides along inside `onQueryChange`.
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
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("queue.loading.button", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
