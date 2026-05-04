import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    let configuredSources: [QueueItem.Source]
    let onSelectResult: (SearchResult) -> Void

    @State private var selectedSource: QueueItem.Source

    init(viewModel: SearchViewModel, configuredSources: [QueueItem.Source],
         onSelectResult: @escaping (SearchResult) -> Void) {
        self.viewModel = viewModel
        self.configuredSources = configuredSources
        self.onSelectResult = onSelectResult
        _selectedSource = State(initialValue: configuredSources.first ?? .radarr)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField(placeholder, text: $viewModel.query)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .onChange(of: viewModel.query) { _, _ in
                        viewModel.onQueryChange(source: selectedSource)
                    }
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

            // Sub-tabs (only if >1 source)
            if configuredSources.count > 1 {
                subTabs
            }

            Divider().padding(.top, 4)

            // Results area
            ScrollView {
                resultContent
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 440)
        }
        .onChange(of: selectedSource) { _, _ in
            viewModel.resetForSource()
            if !viewModel.query.isEmpty {
                viewModel.onQueryChange(source: selectedSource)
            }
        }
    }

    private var placeholder: String {
        selectedSource == .radarr ? "Search movies…" : "Search shows…"
    }

    private var subTabs: some View {
        HStack(spacing: 0) {
            ForEach(configuredSources, id: \.self) { source in
                Button {
                    selectedSource = source
                } label: {
                    VStack(spacing: 0) {
                        Text(source.displayName)
                            .font(.system(size: 11, weight: selectedSource == source ? .semibold : .regular))
                            .foregroundStyle(selectedSource == source ? .primary : .secondary)
                            .padding(.vertical, 6)
                        Rectangle()
                            .fill(selectedSource == source ? Color.accentColor : Color.clear)
                            .frame(height: 1.5)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var resultContent: some View {
        if viewModel.isSearching {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if let err = viewModel.errorMessage {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(12)
        } else if viewModel.query.isEmpty {
            EmptyView()
        } else if viewModel.results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No results")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            let lastID = viewModel.results.last?.id
            LazyVStack(spacing: 0) {
                ForEach(viewModel.results) { result in
                    SearchResultRow(result: result) { onSelectResult(result) }
                    if result.id != lastID {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
