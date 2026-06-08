import SwiftUI

public struct SearchView: View {
    @Bindable var viewModel: SearchViewModel
    @EnvironmentObject var configStore: ConfigStore
    let onSelectResult: (SearchResult) -> Void

    @State private var radarrCollapsed = false
    @State private var sonarrCollapsed = false
    @State private var lidarrCollapsed = false
    @State private var whisparrCollapsed = false
    @State private var radarrShowAll = false
    @State private var sonarrShowAll = false
    @State private var lidarrShowAll = false
    @State private var whisparrShowAll = false
    @FocusState private var queryFocused: Bool

    private static let collapsedLimit = 5

    public init(viewModel: SearchViewModel, onSelectResult: @escaping (SearchResult) -> Void) {
        self.viewModel = viewModel
        self.onSelectResult = onSelectResult
    }

    private var radarrConfigured: Bool { configStore.radarr.isConfigured || DemoMode.isActive }
    private var sonarrConfigured: Bool { configStore.sonarr.isConfigured || DemoMode.isActive }
    private var lidarrConfigured: Bool { configStore.lidarr.isConfigured || DemoMode.isActive }
    private var whisparrConfigured: Bool { configStore.whisparr.isConfigured }

    private var orderedSources: [QueueItem.Source] {
        configStore.arrOrder.compactMap { key -> QueueItem.Source? in
            guard let src = QueueItem.Source(rawValue: key) else { return nil }
            switch src {
            case .radarr: return radarrConfigured ? .radarr : nil
            case .sonarr: return sonarrConfigured ? .sonarr : nil
            case .lidarr: return lidarrConfigured ? .lidarr : nil
            case .whisparr: return whisparrConfigured ? .whisparr : nil
            }
        }
    }

    public var body: some View {
        // On macOS the search field floats at the bottom (Apple's recent
        // Spotlight direction — also a popover-friendly anchor since there's
        // no nav bar). On iOS the shell sets `.searchable(...)` on its
        // NavigationStack, which puts the field in the nav bar — the
        // expected iOS pattern (Mail / Notes / App Store / Files all do
        // this). The ZStack keeps the bar a stable sibling on macOS so
        // focus survives the empty-vs-loading-vs-results swap.
        #if os(macOS)
        ZStack(alignment: .bottom) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            searchBar
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .onChange(of: viewModel.query) { _, oldValue in
            if oldValue != viewModel.query {
                radarrShowAll = false
                sonarrShowAll = false
                lidarrShowAll = false
                whisparrShowAll = false
            }
            viewModel.onQueryChange()
        }
        .task { queryFocused = true }
        #else
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.query) { _, oldValue in
                if oldValue != viewModel.query {
                    radarrShowAll = false
                    sonarrShowAll = false
                    lidarrShowAll = false
                    whisparrShowAll = false
                }
                viewModel.onQueryChange()
            }
        #endif
    }

    @ViewBuilder
    private func sourceSection(_ source: QueueItem.Source) -> some View {
        let results: [SearchResult] = {
            switch source {
            case .radarr: return viewModel.radarrResults
            case .sonarr: return viewModel.sonarrResults
            case .lidarr: return viewModel.lidarrResults
            case .whisparr: return viewModel.whisparrResults
            }
        }()
        let isCollapsed: Bool = {
            switch source {
            case .radarr: return radarrCollapsed
            case .sonarr: return sonarrCollapsed
            case .lidarr: return lidarrCollapsed
            case .whisparr: return whisparrCollapsed
            }
        }()
        let showAll: Bool = {
            switch source {
            case .radarr: return radarrShowAll
            case .sonarr: return sonarrShowAll
            case .lidarr: return lidarrShowAll
            case .whisparr: return whisparrShowAll
            }
        }()
        let title: LocalizedStringKey = {
            switch source {
            case .radarr: return "Movies"
            case .sonarr: return "Series"
            case .lidarr: return "Artists"
            case .whisparr: return "Scenes"
            }
        }()
        let visibleResults: [SearchResult] = (showAll || results.count <= Self.collapsedLimit)
            ? results
            : Array(results.prefix(Self.collapsedLimit))
        let hiddenCount = results.count - visibleResults.count

        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Button {
                withAnimation(.smooth(duration: 0.18)) {
                    switch source {
                    case .radarr: radarrCollapsed.toggle()
                    case .sonarr: sonarrCollapsed.toggle()
                    case .lidarr: lidarrCollapsed.toggle()
                    case .whisparr: whisparrCollapsed.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .scaledFont(size: 9, weight: .semibold)
                        .foregroundStyle(.tertiary)
                    // Source glyph (tv / film / music.note / etc) —
                    // matches the queue-section header so users see the
                    // same arr-source visual on both surfaces.
                    ServiceIcon(source: source, size: 11)
                        .foregroundStyle(.secondary)
                    Text(title, bundle: .module)
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "\(results.count)")
                        .scaledFont(size: 11)
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
                    // Single "No matches." line — per UX review,
                    // differentiating "nothing to add" vs "nothing in
                    // library" is a distinction users don't think in.
                    // Per-source copy ("No movies / series / artists")
                    // was clutter in a 340pt-wide popover.
                    Text("No matches.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else {
                    ForEach(visibleResults) { r in
                        SearchResultRow(result: r) { onSelectResult(r) }
                    }
                    if hiddenCount > 0 {
                        Button {
                            withAnimation(.smooth(duration: 0.18)) {
                                switch source {
                                case .radarr: radarrShowAll = true
                                case .sonarr: sonarrShowAll = true
                                case .lidarr: lidarrShowAll = true
                                case .whisparr: whisparrShowAll = true
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.down")
                                    .scaledFont(size: 9, weight: .semibold)
                                Text("Show \(hiddenCount) more", bundle: .module)
                                    .scaledFont(size: 11, weight: .medium)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// The result area underneath the floating search bar. Three states:
    ///   - empty query → onboarding hint
    ///   - searching → full-screen loader (sticky from first keystroke
    ///     through every subsequent fetch until the final results land,
    ///     so the user never sees a flicker between partial results and
    ///     spinner while typing)
    ///   - settled → per-arr sections
    @ViewBuilder
    private var content: some View {
        if viewModel.query.isEmpty && !viewModel.isSearching {
            emptyHint
        } else if viewModel.isSearching {
            VStack {
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(orderedSources, id: \.self) { src in
                        sourceSection(src)
                    }
                    Color.clear.frame(height: 58)
                }
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchBar: some View {
        // Sized to match the chat input bar's visual weight. The previous
        // 12pt magnifyingglass + 13pt field + 8pt vertical padding gave a
        // cramped ~30pt pill that read as "lightweight chip". Bumped to
        // 15pt icons + 14pt field + 10pt padding → ~38pt tall, parity
        // with the chat input. Same `.glassyFloatingBar()` chrome.
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(.tertiary)
            TextField(
                String(localized: "Search movies and TV series", bundle: .module),
                text: $viewModel.query
            )
            .scaledFont(size: 14)
            .textFieldStyle(.plain)
            .focused($queryFocused)
            if !viewModel.query.isEmpty {
                Button { viewModel.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search", bundle: .module))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassyFloatingBar()
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 26, weight: .light)
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
