import SwiftUI

public struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    @EnvironmentObject var configStore: ConfigStore
    let onSelectResult: (SearchResult) -> Void

    @State private var radarrCollapsed = false
    @State private var sonarrCollapsed = false

    public init(viewModel: SearchViewModel, onSelectResult: @escaping (SearchResult) -> Void) {
        self.viewModel = viewModel
        self.onSelectResult = onSelectResult
    }

    private var radarrConfigured: Bool { configStore.radarr.isConfigured || DemoMode.isActive }
    private var sonarrConfigured: Bool { configStore.sonarr.isConfigured || DemoMode.isActive }

    private var orderedSources: [QueueItem.Source] {
        configStore.arrOrder.compactMap { key -> QueueItem.Source? in
            guard let src = QueueItem.Source(rawValue: key) else { return nil }
            switch src {
            case .radarr: return radarrConfigured ? .radarr : nil
            case .sonarr: return sonarrConfigured ? .sonarr : nil
            case .lidarr: return nil
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if viewModel.query.isEmpty && !viewModel.isSearching {
                emptyHint
            } else if viewModel.isSearching {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(orderedSources, id: \.self) { src in
                            sourceSection(src)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.onQueryChange()
        }
    }

    @ViewBuilder
    private func sourceSection(_ source: QueueItem.Source) -> some View {
        let results = source == .radarr ? viewModel.radarrResults : viewModel.sonarrResults
        let isCollapsed = source == .radarr ? radarrCollapsed : sonarrCollapsed
        let title: LocalizedStringKey = source == .radarr ? "Movies" : "Series"

        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Button {
                withAnimation(.smooth(duration: 0.18)) {
                    if source == .radarr {
                        radarrCollapsed.toggle()
                    } else {
                        sonarrCollapsed.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(title, bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(results.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                if results.isEmpty {
                    let noMatchKey: LocalizedStringKey = source == .radarr
                        ? "No movies match this query."
                        : "No series match this query."
                    Text(noMatchKey, bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else {
                    ForEach(results) { r in
                        SearchResultRow(result: r) { onSelectResult(r) }
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            TextField(
                String(localized: "Search movies and TV series", bundle: .module),
                text: $viewModel.query
            )
            .font(.system(size: 12))
            .textFieldStyle(.plain)
            if !viewModel.query.isEmpty {
                Button { viewModel.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Start typing to search across Radarr and Sonarr.", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
