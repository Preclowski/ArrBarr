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
    @State private var moviesLoading = true
    @State private var seriesLoading = false
    @State private var seriesLoaded = false
    @State private var kind: Kind = .movie
    @State private var enlargedPoster: URL?

    enum Kind: Hashable { case movie, series }

    public init(ref: PersonRef) { self.ref = ref }

    private var ownedCount: Int { movieRows.filter { $0.inLibraryArrId != nil }.count }

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
                    header
                    filmographyPicker
                    filmography
                    footerLinks
                }
                .padding(.horizontal, 14)
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
        .task(id: ref.tmdbId) { await loadInitial() }
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
                    if ownedCount > 0 {
                        Label {
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("person.inLibraryCount", bundle: .module, comment: ""), ownedCount))
                        } icon: { Image(systemName: "checkmark.circle.fill") }
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 1)
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

    /// Movies / Series toggle in the app's own pill idiom (matching the
    /// season / disc pill bars) rather than the system segmented control,
    /// which reads as foreign glass next to the rest of the detail chrome.
    private var filmographyPicker: some View {
        HStack(spacing: 6) {
            kindPill("person.movies.button", .movie)
            kindPill("person.series.button", .series)
            Spacer(minLength: 0)
        }
    }

    private func kindPill(_ key: LocalizedStringKey, _ value: Kind) -> some View {
        let isActive = kind == value
        return Button {
            guard kind != value else { return }
            withAnimation(.smooth(duration: 0.2)) { kind = value }
            if value == .series, !seriesLoaded { Task { await loadSeries() } }
        } label: {
            Text(key, bundle: .module)
                .scaledFont(size: 11, weight: isActive ? .semibold : .medium)
                .foregroundStyle(isActive ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(isActive ? Color.primary.opacity(0.12) : Color.clear))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(isActive ? 0 : 0.18), lineWidth: 0.6))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var filmography: some View {
        let rows = kind == .movie ? movieRows : seriesRows
        let loading = kind == .movie ? moviesLoading : seriesLoading
        if loading && rows.isEmpty {
            SkeletonRows(count: 6)
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
            onTap: { DetailRequest.tap(result) }
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

    // MARK: - Footer

    @ViewBuilder
    private var footerLinks: some View {
        if let details {
            HStack(spacing: 14) {
                if let url = details.tmdbURL { externalLink("TMDB", url) }
                if let url = details.imdbURL { externalLink("IMDb", url) }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    private func externalLink(_ label: String, _ url: URL) -> some View {
        Button { PlatformURLOpener.open(url) } label: {
            HStack(spacing: 3) {
                Text(verbatim: label).scaledFont(size: 12, weight: .medium)
                Image(systemName: "arrow.up.right.square").scaledFont(size: 10, weight: .medium)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading

    private func loadInitial() async {
        let key = configStore.tmdbApiKey
        async let d = PersonStore.shared.details(personId: ref.tmdbId, tmdbKey: key)
        async let m = PersonStore.shared.movieFilmography(
            personId: ref.tmdbId, tmdbKey: key, radarrConfig: configStore.radarr)
        details = await d
        detailsLoading = false
        movieRows = await m
        moviesLoading = false
    }

    private func loadSeries() async {
        seriesLoading = true
        seriesRows = await PersonStore.shared.seriesFilmography(
            personId: ref.tmdbId, tmdbKey: configStore.tmdbApiKey)
        seriesLoading = false
        seriesLoaded = true
    }
}
