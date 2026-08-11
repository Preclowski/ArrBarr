import SwiftUI

/// Identity of a person to open — pushed as a `navigationDestination(item:)`
/// from cast heads. Carries just enough to render the header instantly (name +
/// headshot) while `PersonStore` fetches the bio and filmography.
public struct PersonRef: Hashable, Identifiable, Sendable {
    public let tmdbId: Int
    public let name: String
    public let profilePath: String?
    public var id: Int { tmdbId }

    public init(tmdbId: Int, name: String, profilePath: String? = nil) {
        self.tmdbId = tmdbId
        self.name = name
        self.profilePath = profilePath
    }

    /// Build from a tapped cast head (both providers stamp `tmdbPersonId`).
    public init?(castMember m: CastMember) {
        guard let id = m.tmdbPersonId, id > 0 else { return nil }
        self.init(tmdbId: id, name: m.name, profilePath: nil)
    }
}

public extension View {
    /// Attach a person destination to any cast-showing surface. The surface
    /// owns a `@State PersonRef?`; a cast-head tap sets it and this pushes the
    /// view. Owned by each surface (not a global) so back returns to the
    /// originating detail and nested pushes don't collide.
    func personDestination(_ ref: Binding<PersonRef?>) -> some View {
        navigationDestination(item: ref) { PersonView(ref: $0) }
    }
}

/// A person's page: headshot, bio, and filmography rendered as the same
/// `SearchResultRow`s the search surface uses (owned → detail, new → add).
/// The external IMDb / TMDB links that cast heads used to open directly now
/// live here, in the footer.
public struct PersonView: View {
    let ref: PersonRef
    @EnvironmentObject private var configStore: ConfigStore
    @Environment(\.isDetachedWindow) private var isDetachedWindow
    @Environment(\.dismiss) private var dismiss

    @State private var details: TMDBPersonDetails?
    @State private var detailsLoading = true
    @State private var movieRows: [SearchResult] = []
    @State private var seriesRows: [SearchResult] = []
    /// Both filmographies load up front (two parallel calls) so switching tabs
    /// is instant — no per-switch fetch — and the tab counts are known.
    @State private var filmographyLoading = true
    @State private var kind: Kind = .movie
    @State private var enlargedPoster: URL?
    /// Local title pushes so back returns HERE (owned → detail, new → add).
    /// Routing titles through the root `DetailRequest` tore the nav stack down
    /// to the root, which is what sent "back" to the wrong tab.
    @State private var titleDetail: QueueItem?
    @State private var titleAdd: SearchResult?
    /// Own SearchViewModel for the pushed add panel (it loads quality/root
    /// options from the configs `setup` supplies).
    @State private var searchVM = SearchViewModel()

    enum Kind: Hashable { case movie, series }

    public init(ref: PersonRef) { self.ref = ref }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Detached window / popover draw no NavigationStack chevron — mirror
            // the other detail surfaces and self-draw a back header.
            HStack(spacing: 6) {
                FloatingBackButton(action: { dismiss() })
                    .keyboardShortcut(.cancelAction)
                Text(ref.name)
                    .scaledFont(size: 15, weight: .semibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Header (photo, bio, external links) and the segmented
                    // toggle are padded to 14; the filmography rows are
                    // full-bleed (they self-inset 12) so they don't sit doubly
                    // indented under the header.
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        filmographyToggle
                    }
                    .padding(.horizontal, 14)
                    filmography
                }
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .posterLightbox(url: $enlargedPoster, apiKey: nil, aspectRatio: 1)
        .conditionalNavTitle(ref.name, apply: !isDetachedWindow)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        // Local title pushes — owned drills into the detail, a new title opens
        // the add panel, both popping back to this person view.
        .navigationDestination(item: $titleDetail) { item in
            DetailView(item: item, onBack: { titleDetail = nil }, viewModel: QueueViewModel.shared)
        }
        .navigationDestination(item: $titleAdd) { result in
            SearchAddPanel(result: result, viewModel: searchVM) { titleAdd = nil }
        }
        .task(id: ref.tmdbId) { await loadInitial() }
        .task {
            searchVM.setup(
                radarrConfig: configStore.radarr, sonarrConfig: configStore.sonarr,
                lidarrConfig: configStore.lidarr, whisparrConfig: configStore.whisparr,
                tmdbApiKey: configStore.tmdbApiKey)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    withAnimation(.smooth(duration: 0.22)) { enlargedPoster = photoURL }
                } label: {
                    RemotePoster(
                        url: photoURL,
                        apiKey: nil,
                        tier: .card,
                        size: CGSize(width: 96, height: 96),
                        cornerRadius: 48,
                        fallbackSymbol: "person.fill"
                    )
                }
                .buttonStyle(.plain)
                .disabled(photoURL == nil)

                VStack(alignment: .leading, spacing: 4) {
                    Text(ref.name)
                        .scaledFont(size: 17, weight: .semibold)
                        .lineLimit(2)
                    if let sub = ageBirthplace {
                        Text(sub)
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if detailsLoading {
                        SkeletonLines(count: 1)
                    }
                    // External links live at the top (next to the identity),
                    // as the services' brand icons.
                    if let details {
                        HStack(spacing: 10) {
                            if let url = details.tmdbURL { serviceLink("rating-tmdb", url, "TMDB") }
                            if let url = details.imdbURL { serviceLink("rating-imdb", url, "IMDb") }
                        }
                        .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }

            if let bio = details?.biography, !bio.isEmpty {
                ExpandableOverview(text: bio)
            } else if detailsLoading {
                SkeletonLines(count: 3)
            }
        }
        .padding(.top, 2)
    }

    private var photoURL: URL? {
        details?.profileURL ?? TMDBClient.imageURL(path: ref.profilePath, size: "w185")
    }

    private var ageBirthplace: String? {
        guard let details else { return nil }
        var bits: [String] = []
        if let age = details.age {
            bits.append(String.localizedStringWithFormat(
                NSLocalizedString("person.ageYears", bundle: .module, comment: ""), age))
        }
        if let place = details.placeOfBirth, !place.isEmpty { bits.append(place) }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    // MARK: - Filmography

    /// ONE segmented Movies/Series switch — a single capsule track with the
    /// active half filled that slides between the two. Both filmographies are
    /// already loaded, so switching is a pure local state flip (no fetch, no
    /// list-swap animation — that was the jank) with just the indicator sliding.
    private var filmographyToggle: some View {
        // Movies show "owned/total" (they cross-reference the Radarr library);
        // series can't be library-tagged from a TMDB tv id, so just the total.
        let ownedMovies = movieRows.count { $0.inLibraryArrId != nil }
        return HStack(spacing: 0) {
            segment("person.movies.button", count: "\(ownedMovies)/\(movieRows.count)", .movie)
            segment("person.series.button", count: "\(seriesRows.count)", .series)
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .fixedSize()
        .animation(.smooth(duration: 0.18), value: kind)
    }

    private func segment(_ key: LocalizedStringKey, count: String, _ value: Kind) -> some View {
        let isActive = kind == value
        return Button {
            kind = value
        } label: {
            HStack(spacing: 4) {
                Text(key, bundle: .module)
                // Count appears once the filmography has loaded — "Movies 11/123".
                if !filmographyLoading {
                    Text(verbatim: count)
                        .foregroundStyle(.tertiary)
                }
            }
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background {
                if isActive {
                    Capsule().fill(Color.primary.opacity(0.14))
                        .matchedGeometryEffect(id: "personKindSel", in: kindNS)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @Namespace private var kindNS

    @ViewBuilder
    private var filmography: some View {
        let rows = kind == .movie ? movieRows : seriesRows
        if filmographyLoading && rows.isEmpty {
            SkeletonRows(count: 6)
                .padding(.horizontal, 12)
        } else if rows.isEmpty {
            Text("person.noTitles.label", bundle: .module)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        } else {
            VStack(spacing: 2) {
                ForEach(rows) { result in
                    filmographyRow(result)
                }
            }
        }
    }

    /// A filmography row. Reuses the shared `PosterMetadataRow` primitive
    /// directly rather than `SearchResultRow`: the person tab already says
    /// movie-vs-series, so the source badge would be redundant, and one
    /// affordance (chevron for owned / plus for new) reads cleaner than the
    /// search row's title-chevron + trailing pair. The second line carries
    /// rating and genres — the year lives in the title.
    private func filmographyRow(_ result: SearchResult) -> some View {
        let owned = result.inLibraryArrId != nil
        return PosterMetadataRow(
            posterURL: result.posterURL,
            posterAPIKey: nil,
            posterSize: CGSize(width: 30, height: 44),
            posterBlurred: configStore.shouldBlurPoster(for: result.source),
            posterFallbackSymbol: result.source.symbol,
            title: result.year.map { "\(result.title) (\($0))" } ?? result.title,
            metadataSegments: filmographyMetadata(result),
            titleBadge: owned ? AnyView(InLibraryBadge()) : nil,
            showTitleChevron: false,
            onTap: { openTitle(result) }
        ) {
            if owned {
                LinkChevron(size: 10)
            } else {
                Image(systemName: "plus")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func filmographyMetadata(_ result: SearchResult) -> [String] {
        var out: [String] = []
        if let r = result.rating { out.append(String(format: "★%.1f", r)) }
        out.append(contentsOf: result.genres.prefix(2))
        return out
    }

    /// Open a filmography title LOCALLY so back returns to this person view.
    /// Owned → the detail (via the arr-internal id); new → the add panel.
    private func openTitle(_ result: SearchResult) {
        if let arrId = result.inLibraryArrId {
            titleDetail = DetailRequest.syntheticItem(
                source: result.source, entityId: arrId, title: result.title)
        } else {
            titleAdd = result
        }
    }

    // MARK: - External links

    /// A brand-icon link to the service's page for this person.
    private func serviceLink(_ icon: String, _ url: URL, _ accessibility: String) -> some View {
        Button { PlatformURLOpener.open(url) } label: {
            Image(icon, bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: accessibility))
        .accessibilityLabel(Text(verbatim: accessibility))
        #if os(macOS)
        .onHover { if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        #endif
    }

    // MARK: - Loading

    private func loadInitial() async {
        let key = configStore.tmdbApiKey
        async let d = PersonStore.shared.details(personId: ref.tmdbId, tmdbKey: key)
        async let m = PersonStore.shared.movieFilmography(
            personId: ref.tmdbId, tmdbKey: key, radarrConfig: configStore.radarr)
        async let s = PersonStore.shared.seriesFilmography(personId: ref.tmdbId, tmdbKey: key)
        details = await d
        detailsLoading = false
        movieRows = await m
        seriesRows = await s
        filmographyLoading = false
    }
}
