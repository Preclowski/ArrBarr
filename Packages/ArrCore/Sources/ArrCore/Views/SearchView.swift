import SwiftUI

public struct SearchView: View {
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

    public var body: some View {
        #if os(iOS)
        // iOS: search field floats at the bottom as a Liquid Glass capsule.
        // Content scrolls *behind* it (so the blur reads), with bottom inset
        // applied so the last row clears the bar.
        VStack(spacing: 0) {
            if configuredSources.count > 1 {
                subTabs
                Divider().padding(.top, 4)
            }
            ScrollView {
                resultContent
                    .padding(.bottom, 88) // clear the floating bar
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .overlay(alignment: .bottom) {
            FloatingGlassSearchBar(
                placeholder: placeholder,
                query: $viewModel.query
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .onChange(of: selectedSource) { _, _ in
            viewModel.resetForSource()
            if !viewModel.query.isEmpty {
                viewModel.onQueryChange(source: selectedSource)
            }
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.onQueryChange(source: selectedSource)
        }
        #else
        // macOS popover: inline field at the top — floating glass would look
        // wrong inside a 320pt popover.
        VStack(spacing: 0) {
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

            if configuredSources.count > 1 {
                subTabs
            }

            Divider().padding(.top, 4)

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
        #endif
    }

    private var placeholder: String {
        selectedSource == .radarr ? "Search movies…" : "Search shows…"
    }

    /// Empty-state copy that fills the body before the user types. Without
    /// it the popover looks broken — search bar, then nothing.
    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: selectedSource == .radarr ? "film.stack" : "tv.inset.filled")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text(emptyHeadline)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(emptyHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
    }

    private var emptyHeadline: LocalizedStringKey {
        selectedSource == .radarr
            ? "Find a movie to add"
            : "Find a show to add"
    }

    private var emptyHint: LocalizedStringKey {
        selectedSource == .radarr
            ? "Type a title above to search TMDB through Radarr's lookup, then add it to your library."
            : "Type a title above to search TVDB through Sonarr's lookup, then add it to your library."
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
            emptyPrompt
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

#if os(iOS)
/// Floating Liquid Glass search bar for iOS. Sits at the bottom of the screen,
/// capsule-shaped, content scrolls behind it.
///
/// On iOS 26 we use `.glassEffect()` for true Liquid Glass; earlier OSes
/// fall back to `.ultraThinMaterial` which is the closest visual approximation.
private struct FloatingGlassSearchBar: View {
    let placeholder: String
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $query)
                .font(.system(size: 16))
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(glassBackground)
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 6)
        .animation(.easeInOut(duration: 0.18), value: query.isEmpty)
    }

    /// `ultraThinMaterial` reads as Liquid Glass on iOS 26 (the system swaps
    /// material rendering in) and as a vibrant blur on iOS 17+. Same call site,
    /// no `#available` gate needed.
    private var glassBackground: some View {
        Capsule().fill(.ultraThinMaterial)
    }
}
#endif
