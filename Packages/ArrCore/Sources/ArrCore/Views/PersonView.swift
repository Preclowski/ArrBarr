import SwiftUI
import os
import MediaKit

/// Carries enough to render the header instantly while `People` fetches bio and filmography.
nonisolated public struct PersonRef: Hashable, Identifiable, Sendable {
    public let tmdbId: Int
    public let name: String
    public let profilePath: String?
    public var id: Int { tmdbId }

    public init(tmdbId: Int, name: String, profilePath: String? = nil) {
        self.tmdbId = tmdbId
        self.name = name
        self.profilePath = profilePath
    }

    /// Both providers stamp `tmdbPersonId`.
    public init?(castMember m: CastMember) {
        guard let id = m.tmdbPersonId, id > 0 else { return nil }
        self.init(tmdbId: id, name: m.name, profilePath: nil)
    }
}

public extension View {
    /// Each surface owns its `@State PersonRef?` (not a global) so back returns to the originating detail
    /// and nested pushes don't collide.
    func personDestination(_ ref: Binding<PersonRef?>) -> some View {
        navigationDestination(item: ref) { r in
            PersonView(ref: r, onBack: { ref.wrappedValue = nil })
        }
    }
}

struct PersonView: View {
    let ref: PersonRef
    @EnvironmentObject private var configStore: ConfigStore
    @Environment(\.isDetachedWindow) private var isDetachedWindow
    /// Explicit pop callback: reading `dismiss` in a view that declares `navigationDestination` re-renders
    /// the whole stack at ~150 Hz.
    let onBack: () -> Void

    @State private var details: TMDBPersonDetails?
    @State private var detailsLoading = true
    @State private var movieRows: [SearchResult] = []
    @State private var seriesRows: [SearchResult] = []
    /// Both load up front so switching tabs needs no fetch and the counts are known.
    @State private var filmographyLoading = true
    /// Why the page is empty when TMDB didn't answer; distinct from a person with no credits.
    @State private var loadError: String?
    @State private var kind: Kind = .movie
    @State private var enlargedPoster: URL?
    /// Local pushes: routing through the root `DetailRequest` tears the stack down, so back lands on the wrong tab.
    @State private var titleDetail: QueueItem?
    @State private var titleAdd: SearchResult?
    @State private var searchVM = SearchViewModel()

    enum Kind: Hashable { case movie, series }

    init(ref: PersonRef, onBack: @escaping () -> Void = {}) {
        self.ref = ref
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 6) {
                FloatingBackButton(action: onBack)
                    .keyboardShortcut(.cancelAction)
                Text(displayName)
                    .scaledFont(size: 15, weight: .semibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
                TrailingMenu { moreActions } label: { HeaderGlyph(systemName: "ellipsis") }
                    .help(Text("common.moreActions.button", bundle: .module))
                    .accessibilityLabel(Text("common.moreActions.button", bundle: .module))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            #endif

            ScrollView {
                // LazyVStack with the ForEach as direct children: an eager VStack of 100+ hover-tracked rows pegged the main thread.
                LazyVStack(alignment: .leading, spacing: 2) {
                    // Rows are full-bleed (they self-inset 12) so they aren't doubly indented under the 14pt header.
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        filmographyToggle
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)

                    let rows = kind == .movie ? movieRows : seriesRows
                    if filmographyLoading && rows.isEmpty {
                        SkeletonRows(count: 6).padding(.horizontal, 12)
                    } else if let loadError, rows.isEmpty {
                        VStack(spacing: 10) {
                            Text(verbatim: loadError)
                                .scaledFont(size: 12)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button { Task { await loadInitial() } } label: { Text("common.retry.button", bundle: .module) }
                                .modifier(GlassButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else if rows.isEmpty {
                        Text("person.noTitles.label", bundle: .module)
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(rows) { result in
                            PersonFilmographyRow(result: result) { openTitle(result) }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .posterLightbox(url: $enlargedPoster, apiKey: nil, aspectRatio: 1)
        .conditionalNavTitle(displayName, apply: !isDetachedWindow)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu { moreActions } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel(Text("common.moreActions.button", bundle: .module))
            }
        }
        #else
        .toolbar(.hidden, for: .windowToolbar)
        #endif
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

    @ViewBuilder
    private var moreActions: some View {
        Button {
            if let url = URL(string: "https://www.themoviedb.org/person/\(ref.tmdbId)") {
                PlatformURLOpener.open(url)
            }
        } label: {
            Label { Text("person.openProfile.button", bundle: .module) } icon: { Image(systemName: "safari") }
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
                    Text(displayName)
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

    /// The caller's name is only a label — a chat link carries whatever text the model wrote — so TMDB's name wins once loaded.
    private var displayName: String { details?.name ?? ref.name }

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

    /// Both filmographies are loaded, so switching is a local flip; animating a list swap caused jank.
    private var filmographyToggle: some View {
        // Series can't be library-tagged from a TMDB tv id, so only movies show "owned/total".
        let ownedMovies = movieRows.count { $0.inLibraryArrId != nil }
        let ownedSeries = seriesRows.count { $0.inLibraryArrId != nil }
        return HStack(spacing: 0) {
            segment("person.movies.button", count: "\(ownedMovies)/\(movieRows.count)", .movie)
            segment("person.series.button", count: "\(ownedSeries)/\(seriesRows.count)", .series)
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

    private func openTitle(_ result: SearchResult) {
        if let arrId = result.inLibraryArrId {
            titleDetail = DetailRequest.syntheticItem(
                source: result.source, entityId: arrId, title: result.title)
        } else {
            titleAdd = result
        }
    }

    // MARK: - External links

    private func serviceLink(_ icon: String, _ url: URL, _ label: String) -> some View {
        Button { PlatformURLOpener.open(url) } label: {
            HStack(spacing: 4) {
                Image(icon, bundle: .module)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 12)
                Text(verbatim: label)
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        #if os(macOS)
        .onHover { if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        #endif
    }

    // MARK: - Loading

    /// Logs when the opening label and the person the id resolves to differ: a credit whose name and image
    /// don't belong to its `personTmdbId`, invisible unless someone recognises the face.
    private static let identityLog = Logger(category: "SeriesIdentity")

    private static func warnIfIdentityDisagrees(ref: PersonRef, details: TMDBPersonDetails?) {
        guard let details,
              TitleMatch.normalize(details.name) != TitleMatch.normalize(ref.name) else { return }
        identityLog.notice("""
            person \(ref.tmdbId, privacy: .public): opened as "\(ref.name, privacy: .private)" \
            but tmdb calls that id "\(details.name, privacy: .private)"
            """)
    }

    private func loadInitial() async {
        let key = configStore.tmdbApiKey
        loadError = nil
        detailsLoading = true
        filmographyLoading = true
        defer { detailsLoading = false; filmographyLoading = false }
        do {
            async let d = People.details(personId: ref.tmdbId, tmdbKey: key)
            async let m = People.movieFilmography(
                personId: ref.tmdbId, tmdbKey: key, radarrConfig: configStore.radarr)
            async let s = People.seriesFilmography(
                personId: ref.tmdbId, tmdbKey: key, sonarrConfig: configStore.sonarr)
            details = try await d
            Self.warnIfIdentityDisagrees(ref: ref, details: details)
            (movieRows, seriesRows) = try await (m, s)
        } catch {
            Self.identityLog.error("person \(ref.tmdbId, privacy: .public) failed to load: \(error.logKind, privacy: .public): \(error.localizedDescription, privacy: .private)")
            loadError = String(format: String(localized: "Couldn't load details: %@", bundle: .module), error.localizedDescription)
        }
    }
}

/// No source badge (the tab says movie vs series) and no trailing accessory: ownership reads from the "In library" pill.
private struct PersonFilmographyRow: View {
    let result: SearchResult
    let onTap: () -> Void
    @EnvironmentObject private var configStore: ConfigStore
    #if os(macOS)
    private var hasTooltip: Bool {
        (result.overview.map { !$0.isEmpty } ?? false) || !result.genres.isEmpty
    }
    #endif

    private var metadata: [String] {
        var out: [String] = []
        if let role = result.subtitle, !role.isEmpty { out.append(role) }
        out.append(contentsOf: result.genres.prefix(2))
        return out
    }

    var body: some View {
        let row = PosterMetadataRow(
            posterURL: result.posterURL,
            posterAPIKey: nil,
            posterSize: CGSize(width: 26, height: 38),
            posterBlurred: configStore.shouldBlurPoster(for: result.source),
            posterFallbackSymbol: result.source.symbol,
            title: result.year.map { "\(result.title) (\($0))" } ?? result.title,
            metadataSegments: metadata,
            onTap: onTap,
            // Filmography scores are TMDB's.
            metadataBadge: {
                if let chip = result.rating.flatMap({ RatingChip.tmdb($0) }) { RatingPill(chip: chip) }
            }
        ) {
            if result.inLibraryArrId != nil {
                LibraryStateBadge(isDownloaded: result.libraryDownloaded)
            }
        }
        #if os(macOS)
        row
            .hoverTooltip(enabled: hasTooltip) {
                SearchResultTooltip(result: result).environmentObject(configStore)
            }
        #else
        row
        #endif
    }
}
