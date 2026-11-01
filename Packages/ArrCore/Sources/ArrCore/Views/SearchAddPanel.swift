import SwiftUI
import MediaKit

struct SearchAddPanel: View {
    /// Mutable so a chat result built from a TMDB summary (no IMDb / RT / runtime) can be
    /// swapped for an enriched copy.
    @State private var result: SearchResult
    var viewModel: SearchViewModel
    let onBack: () -> Void

    private var storeManager: StoreManager { .shared }

    /// Frozen at init: enrichment changes `result.id` for a TMDB-sourced series (0 → tvdbId),
    /// which would re-run the cast/trailer tasks and repaint the wrong series.
    private let identityKey: String

    init(result: SearchResult, viewModel: SearchViewModel,
                onBack: @escaping () -> Void) {
        _result = State(initialValue: result)
        self.viewModel = viewModel
        self.onBack = onBack
        self.identityKey = result.id
    }

    /// Nil = no clip (or no TMDB key for the series route), so no poster badge.
    @State private var trailer: TrailerReel?
    @State private var trailerLoading = true
    private var trailerSession: TrailerSession { .shared }
    /// The title is browsed first; the add options open on request.
    @State private var addFormOpen = false
    #if os(iOS)
    /// Sizes the sheet to the form.
    @State private var addFormHeight: CGFloat = 320
    #endif

    // Radarr state
    @State private var selectedProfileId: Int?
    @State private var selectedRootFolder: String?
    @State private var radarrMonitor: RadarrMonitorMode = .movieOnly

    // Sonarr state
    @State private var sonarrMonitor: SonarrMonitorMode = .all
    @State private var seriesType: SonarrSeriesType = .standard
    /// Always on, like Sonarr's own default; kept to preserve the API call shape.
    private let seasonFolder = true

    // Lidarr state
    @State private var selectedMetadataProfileId: Int?

    // Whisparr state
    @State private var whisparrMonitor: RadarrMonitorMode = .movieOnly
    @State private var lidarrMonitor: LidarrMonitorMode = .all
    @State private var enlargedPoster: URL?

    @Environment(ConfigStore.self) private var configStore
    /// Movies/series only; stays empty without a TMDB key.
    @State private var cast: [CastMember] = []
    @State private var directors: [CastMember] = []
    @State private var countries: [String] = []
    /// Drives the cast skeleton so the hero doesn't jump when the strip pops in.
    @State private var castLoading = false
    /// Pushed locally so back returns here.
    @State private var personRef: PersonRef?
    /// TMDB's seasons add artwork, episode counts and dates to the lookup's bare season numbers.
    @State private var tmdbSeasons: [Int: TMDBDetails.Airing] = [:]
    @State private var seasonsLoading = true

    var body: some View {
        ZStack {
            mainContent
                .parked(enlargedPoster != nil)
                // Without these, rows under the scrim still took clicks and opened their tooltips.
                .parked(addFormOpen, opacity: 1)
                .environment(\.suppressRowTooltip, addFormOpen)

            #if os(macOS)
            if addFormOpen {
                addFormOverlay
                    .transition(.opacity)
                    .zIndex(5)
            }
            #endif

            if let url = enlargedPoster {
                PosterLightbox(
                    url: url,
                    apiKey: nil,
                    aspectRatio: result.source == .lidarr ? 1.0 : 2.0 / 3.0,
                    onDismiss: {
                        withAnimation(.smooth(duration: 0.22)) { enlargedPoster = nil }
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
        // No `.navigationTitle`: this overlay draws its own header, and a title would propagate up
        // and stack a second header above it.
        .personDestination($personRef)
        #if os(iOS)
        .sheet(isPresented: $addFormOpen, onDismiss: { viewModel.addError = nil }) {
            addForm
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { addFormHeight = $0 }
                .presentationDetents([.height(addFormHeight)])
                .presentationDragIndicator(.visible)
        }
        #endif
    }

    #if os(macOS)
    /// `.sheet` doesn't render inside a `MenuBarExtra` popover, hence an overlay.
    private var addFormOverlay: some View {
        ZStack(alignment: .bottom) {
            // A Button, so Esc closes the form and VoiceOver gets a way out.
            Button(action: closeAddForm) {
                Rectangle()
                    .fill(.black.opacity(0.32))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .focusEffectDisabled()
            .accessibilityLabel(Text("common.cancel.button", bundle: .module))
            .ignoresSafeArea()

            addForm
                .floatingPanelCard()
        }
    }

    private func closeAddForm() {
        viewModel.addError = nil
        withAnimation(Self.addFormMotion) { addFormOpen = false }
    }
    #endif

    private static let addFormMotion: Animation = .smooth(duration: 0.18)

    private var addForm: some View {
        VStack(spacing: 6) {
            if viewModel.isLoadingOptions {
                // The form's own rows, so the card doesn't grow when the options land.
                SkeletonRows(count: formRowCount, rowHeight: 26, spacing: 4)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            } else {
                if result.source == .radarr {
                    radarrForm
                } else if result.source == .sonarr {
                    sonarrForm
                } else if result.source == .whisparr {
                    whisparrForm
                } else {
                    lidarrForm
                }
            }
            if let err = viewModel.addError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
            }
            addButtons
                .padding(.bottom, 10)
        }
        .padding(.top, 8)
    }

    private var openAddFormButton: some View {
        Button {
            withAnimation(Self.addFormMotion) { addFormOpen = true }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: storeManager.isPro ? "plus" : "lock.fill")
                    .frame(width: CTAButtonStyle.labelSize)
                Text("discover.addToLibrary.button", bundle: .module)
            }
        }
        // The detail view's CTA, as `PauseResumeButton`: the accent staining the glass.
        .buttonStyle(CTAButtonStyle(tint: .accentColor, glass: true))
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header

            // The CTA sits in a sticky footer so a tall overview never hides the action;
            // a safe-area inset lets the overview scroll under the card instead of clipping above it.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    hero
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                }
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                openAddFormButton
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Parallel with loadOptions — they hit different endpoints.
            async let enrich: Void = { @MainActor in
                if needsEnrichment, let enriched = await viewModel.enrich(result) {
                    result = enriched
                }
            }()
            async let options: Void = viewModel.loadOptions(source: result.source)
            _ = await (enrich, options)
            selectedProfileId = viewModel.qualityProfiles.first?.id
            selectedRootFolder = viewModel.rootFolders.first
            selectedMetadataProfileId = viewModel.metadataProfiles.first?.id
        }
        .task(id: identityKey) {
            // `addError` lives on the shared SearchViewModel; clear it or the last failure shows
            // under the next title.
            viewModel.addError = nil
            await loadCast()
        }
        .task(id: identityKey) { await resolveTrailer() }
        .task(id: identityKey) { await loadTMDBSeasons() }
    }

    /// Chat results from TMDB lack IMDb / RT / Metacritic / runtime; that absence marks them.
    private var needsEnrichment: Bool {
        result.runtime == nil && result.imdb == nil
            && result.rottenTomatoes == nil && result.metacritic == nil
    }

    // MARK: - Header chrome (matches DetailView)

    private var header: some View {
        // An overlay, not a push, so there's no system chevron — draw our own back button.
        HStack(spacing: 6) {
            FloatingBackButton(action: onBack)
                // The open form's scrim takes Esc.
                .keyboardShortcut(addFormOpen ? nil : KeyboardShortcut.cancelAction)
            Text(verbatim: navTitleString)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// `mediaRef` already knows the foreign key, so no second source check.
    private func resolveTrailer() async {
        // Dismiss only OUR previous clip — a fresh mount must not kill a session restored across a reopen.
        if trailerSession.isShowing(trailer) { trailerSession.dismiss() }
        trailer = nil
        trailerLoading = true
        var reel: TrailerReel?
        switch result.mediaRef {
        case .tmdb(let id):
            reel = await TrailerProvider.movieReel(
                radarrTrailerId: nil, tmdbId: id, configStore: configStore
            )
        case .tvdb(let id):
            // Pass the TMDB id when there is one: one request instead of `/find` plus one.
            reel = await TrailerProvider.seriesReel(
                tmdbId: result.tmdbTVId, tvdbId: id, configStore: configStore
            )
        case .tmdbTV(let id):
            // Not yet resolved to a tvdbId — only TMDB knows this show.
            reel = await TrailerProvider.seriesReel(
                tmdbId: id, tvdbId: nil, configStore: configStore
            )
        case .musicBrainz, .imdb:
            break
        }
        guard !Task.isCancelled else { return }
        withAnimation(DetailView.landing) {
            trailer = reel
            trailerLoading = false
        }
    }

    private var navTitleString: String {
        if let y = result.year, y > 0 {
            return "\(result.title) (\(y))"
        }
        return result.title
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            MediaHeaderCard(
                title: result.title,
                subtitle: result.subtitle,
                year: result.year,
                runtime: result.runtime,
                network: result.network,
                certification: result.certification,
                countries: countries,
                genres: result.genres,
                ratings: ratingChips,
                overview: result.overview,
                posterURL: result.posterURL,
                fallbackSymbol: result.source == .sonarr ? "tv" : (result.source == .lidarr ? "music.note" : (result.source == .whisparr ? "flame" : "film")),
                posterAspect: 2.0/3.0,
                // Arrives with the arr's lookup: a lean TMDB row gets it once enriched.
                titleBadge: AnyView(ReleaseStatusChip(status: result.releaseStatus, source: result.source)),
                onPosterTap: { url in
                    withAnimation(.smooth(duration: 0.22)) {
                        enlargedPoster = url ?? result.posterURL
                    }
                },
                // Title + year live in the nav-bar title.
                showTitle: false,
                directedBy: directors,
                directedByKey: result.source == .sonarr ? "detail.createdBy.label" : "detail.directedBy.label",
                onTapPerson: { member in
                    if let ref = PersonRef(castMember: member) { personRef = ref }
                }
            )
            if !cast.isEmpty {
                CastRow(cast: cast, onTapPerson: { member in
                    if let ref = PersonRef(castMember: member) { personRef = ref }
                })
            } else if castLoading {
                SkeletonCastRow()
            }
            if let trailer {
                TrailerRow(reel: trailer)
            } else if trailerLoading, result.source != .lidarr, !configStore.tmdbApiKey.isEmpty {
                SkeletonTrailerRow()
            }
            if result.source == .sonarr {
                seasonList
            }
        }
    }

    /// Sonarr's (TVDB) numbering decides the list, since that is what gets added; TMDB numbers
    /// seasons differently for some shows, so it only fills in seasons whose number matches.
    private var seasonNumbers: [Int] {
        result.seasonNumbers.isEmpty ? tmdbSeasons.keys.filter { $0 > 0 }.sorted() : result.seasonNumbers
    }

    /// Waits for TMDB even when the lookup knows the numbers: without it a row is a bare name.
    @ViewBuilder
    private var seasonList: some View {
        if seasonsLoading, !configStore.tmdbApiKey.isEmpty {
            SkeletonSeasonSection(rows: result.seasonNumbers.isEmpty ? 3 : result.seasonNumbers.count)
        } else if !seasonNumbers.isEmpty {
            SeasonSection(count: seasonNumbers.count) {
                ForEach(seasonNumbers, id: \.self) { number in
                    SeasonRow(number: number, tmdb: tmdbSeasons[number],
                              posterURL: TMDBClient.imageURL(path: tmdbSeasons[number]?.posterPath) ?? result.posterURL)
                }
            }
        }
    }

    private func loadTMDBSeasons() async {
        guard result.source == .sonarr else { return }
        seasonsLoading = true
        let seasons = await DetailView.tmdbSeasons(tmdbId: result.tmdbTVId, tvdbId: result.externalId,
                                                   configStore: configStore)
        guard !Task.isCancelled else { return }
        withAnimation(DetailView.landing) {
            tmdbSeasons = seasons
            seasonsLoading = false
        }
    }

    /// Silent on failure / no key. Passing `tmdbTVId` for series skips the `/find` hop and is
    /// the only route for a TMDB-sourced row, whose tvdbId is still 0.
    private func loadCast() async {
        guard !configStore.tmdbApiKey.isEmpty else { return }
        castLoading = true
        defer { castLoading = false }
        // `CountryProvider`'s cache means DetailView won't refetch it later.
        switch result.source {
        case .radarr, .whisparr:
            // Radarr only: Whisparr's ids aren't guaranteed to be TMDB movie ids.
            async let movieCountries: [String] = result.source == .radarr
                ? CountryProvider.movieCountries(
                    tmdbId: result.externalId, configStore: configStore)
                : []
            let credits = await CastProvider.movieCredits(
                radarrMovieId: nil, tmdbId: result.externalId, configStore: configStore)
            cast = credits.cast
            directors = credits.directors
            countries = await movieCountries
        case .sonarr:
            async let seriesCountries = CountryProvider.seriesCountries(
                tmdbId: result.tmdbTVId, tvdbId: result.externalId,
                configStore: configStore)
            let credits = await CastProvider.seriesCredits(
                tmdbId: result.tmdbTVId, tvdbId: result.externalId,
                configStore: configStore)
            cast = credits.cast
            directors = credits.directors
            countries = await seriesCountries
        case .lidarr:
            break  // no TMDB cast for music
        }
    }

    // MARK: - Lidarr form

    private var lidarrForm: some View {
        VStack(spacing: 4) {
            formPicker("search.qualityProfile.button",
                       selection: Binding(
                           get: { selectedProfileId ?? viewModel.qualityProfiles.first?.id ?? 0 },
                           set: { selectedProfileId = $0 }
                       ),
                       options: viewModel.qualityProfiles.map { ($0.id, $0.name) })

            if viewModel.metadataProfiles.count > 1 {
                formPicker("search.metadataProfile.button",
                           selection: Binding(
                               get: { selectedMetadataProfileId ?? viewModel.metadataProfiles.first?.id ?? 0 },
                               set: { selectedMetadataProfileId = $0 }
                           ),
                           options: viewModel.metadataProfiles.map { ($0.id, $0.name) })
            }

            formPicker("search.rootFolder.button",
                       selection: Binding(
                           get: { selectedRootFolder ?? viewModel.rootFolders.first ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: viewModel.rootFolders.map { ($0, $0) })

            // An album row always monitors just that album (the artist is added with `monitor: none`),
            // so the picker would be a lie there.
            if !result.isLidarrAlbum {
                formPicker("search.monitor.button",
                           selection: $lidarrMonitor,
                           options: LidarrMonitorMode.allCases.map { ($0, $0.displayName) })
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private var ratingChips: [RatingChip] {
        var chips: [RatingChip] = []
        // Movie result.id is the TMDB id, series result.id the TVDB id; site search otherwise.
        if let v = result.imdb, let chip = RatingChip.imdb(v, linkTitle: result.title, imdbId: result.imdbId) {
            chips.append(chip)
        }
        if let v = result.rating {
            let isSeries = result.source == .sonarr
            let url = isSeries
                ? RatingSiteLink.tvdbSeries(id: result.externalId, title: result.title)
                : RatingSiteLink.tmdbMovie(id: result.externalId, title: result.title)
            chips.append(RatingChip(label: isSeries ? "TVDB" : "TMDB",
                                    value: v.ratingText, color: isSeries ? .blue : .teal,
                                    url: url, iconName: isSeries ? "rating-tvdb" : "rating-tmdb"))
        }
        if let v = result.rottenTomatoes {
            chips.append(RatingChip(label: "RT", value: "\(Int(v))%", color: .red,
                                    url: RatingSiteLink.rottenTomatoes(title: result.title), iconName: "rating-rt"))
        }
        if let v = result.metacritic {
            chips.append(RatingChip(label: "MC", value: "\(Int(v))", color: .green,
                                    url: RatingSiteLink.metacritic(title: result.title)))
        }
        return chips
    }

    // MARK: - Whisparr form

    private var whisparrForm: some View {
        VStack(spacing: 4) {
            formPicker("search.qualityProfile.button",
                       selection: Binding(
                           get: { selectedProfileId ?? viewModel.qualityProfiles.first?.id ?? 0 },
                           set: { selectedProfileId = $0 }
                       ),
                       options: viewModel.qualityProfiles.map { ($0.id, $0.name) })

            formPicker("search.rootFolder.button",
                       selection: Binding(
                           get: { selectedRootFolder ?? viewModel.rootFolders.first ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: viewModel.rootFolders.map { ($0, $0) })

            formPicker("search.monitor.button",
                       selection: $whisparrMonitor,
                       options: RadarrMonitorMode.allCases.map { ($0, $0.displayName) })
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private var formRowCount: Int {
        switch result.source {
        case .sonarr, .lidarr: 4
        default: 3
        }
    }

    // MARK: - Radarr form

    private var radarrForm: some View {
        VStack(spacing: 4) {
            formPicker("search.qualityProfile.button",
                       selection: Binding(
                           get: { selectedProfileId ?? viewModel.qualityProfiles.first?.id ?? 0 },
                           set: { selectedProfileId = $0 }
                       ),
                       options: viewModel.qualityProfiles.map { ($0.id, $0.name) })

            formPicker("search.rootFolder.button",
                       selection: Binding(
                           get: { selectedRootFolder ?? viewModel.rootFolders.first ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: viewModel.rootFolders.map { ($0, $0) })

            formPicker("search.monitor.button",
                       selection: $radarrMonitor,
                       options: RadarrMonitorMode.allCases.map { ($0, $0.displayName) })
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    // MARK: - Sonarr form

    private var sonarrForm: some View {
        VStack(spacing: 4) {
            formPicker("search.qualityProfile.button",
                       selection: Binding(
                           get: { selectedProfileId ?? viewModel.qualityProfiles.first?.id ?? 0 },
                           set: { selectedProfileId = $0 }
                       ),
                       options: viewModel.qualityProfiles.map { ($0.id, $0.name) })

            formPicker("search.rootFolder.button",
                       selection: Binding(
                           get: { selectedRootFolder ?? viewModel.rootFolders.first ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: viewModel.rootFolders.map { ($0, $0) })

            formPicker("search.seriesType.button",
                       selection: $seriesType,
                       options: SonarrSeriesType.allCases.map { ($0, $0.displayName) })

            formPicker("search.monitor.button",
                       selection: $sonarrMonitor,
                       options: SonarrMonitorMode.allCases.map { ($0, $0.displayName) })
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    // MARK: - Add button

    /// Two CTAs so an add never starts an indexer search without saying so; "Add and search"
    /// is the prominent, common one.
    private var addButtons: some View {
        HStack(spacing: 8) {
            addButton(searchOnAdd: false)
            addButton(searchOnAdd: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private func addButton(searchOnAdd: Bool) -> some View {
        Button {
            Task {
                guard let pid = selectedProfileId ?? viewModel.qualityProfiles.first?.id,
                      let folder = selectedRootFolder ?? viewModel.rootFolders.first else { return }
                // Whisparr and Radarr both carry `.tmdb` refs, so the inner source check disambiguates.
                switch result.mediaRef {
                case .tmdb where result.source == .whisparr:
                    await viewModel.addScene(result, qualityProfileId: pid,
                                            rootFolderPath: folder, monitor: whisparrMonitor,
                                            searchOnAdd: searchOnAdd)
                case .tmdb:
                    await viewModel.addMovie(result, qualityProfileId: pid,
                                            rootFolderPath: folder, monitor: radarrMonitor,
                                            searchOnAdd: searchOnAdd)
                // `addSeries` resolves the tvdbId before posting and refuses if it can't.
                case .tvdb, .tmdbTV:
                    await viewModel.addSeries(result, qualityProfileId: pid,
                                             rootFolderPath: folder, monitor: sonarrMonitor,
                                             seriesType: seriesType, seasonFolder: seasonFolder,
                                             searchOnAdd: searchOnAdd)
                case .musicBrainz:
                    let metaPid = selectedMetadataProfileId ?? viewModel.metadataProfiles.first?.id ?? 1
                    if result.isLidarrAlbum {
                        // The artist is created unmonitored-for-new so only this album is tracked.
                        await viewModel.addAlbum(result, qualityProfileId: pid,
                                                 metadataProfileId: metaPid, rootFolderPath: folder,
                                                 searchOnAdd: searchOnAdd)
                    } else {
                        await viewModel.addArtist(result, qualityProfileId: pid,
                                                 metadataProfileId: metaPid, rootFolderPath: folder,
                                                 monitor: lidarrMonitor,
                                                 searchOnAdd: searchOnAdd)
                    }
                case .imdb:
                    // The search pipeline should have resolved IMDb-only refs before this UI.
                    viewModel.addError = String(localized: "search.unresolvedImdb.error", bundle: .module)
                }
                if viewModel.addError == nil {
                    // The Quiz drops the card instead of offering something already added.
                    LibraryAddCompletion.post(foreignId: result.foreignId)
                    onBack()
                }
            }
        } label: {
            Group {
                if viewModel.isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    // `LocalizedStringKey`, not `String`: `Text(String)` takes the non-localizing overload.
                    let addLabel: LocalizedStringKey = {
                        switch result.source {
                        case .radarr: return "search.addToRadarr.button"
                        case .sonarr: return "search.addToSonarr.button"
                        case .lidarr: return "search.addToLidarr.button"
                        case .whisparr: return "search.addToWhisparr.button"
                        }
                    }()
                    // The search variant trades the source glyph for a magnifier to tell the two buttons apart.
                    HStack(spacing: 6) {
                        if !storeManager.isPro {
                            Image(systemName: "lock.fill")
                        }
                        if searchOnAdd {
                            Image(systemName: "magnifyingglass")
                            Text("search.addAndSearch.button", bundle: .module)
                        } else {
                            ServiceIcon(source: result.source, size: CTAButtonStyle.labelSize - 1)
                            Text(addLabel, bundle: .module)
                        }
                    }
                }
            }
        }
        // Only one stained button, so the user reaches for it instead of reading.
        .buttonStyle(CTAButtonStyle(tint: searchOnAdd ? .accentColor : nil))
        .disabled(viewModel.isAdding || viewModel.isLoadingOptions)
    }

    // MARK: - Helpers

    private func formPicker<T: Hashable>(_ label: LocalizedStringKey, selection: Binding<T>,
                                         options: [(T, String)]) -> some View {
        HStack {
            Text(label, bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(options, id: \.0) { val, name in
                    Button(name) { selection.wrappedValue = val }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(verbatim: options.first(where: { $0.0 == selection.wrappedValue })?.1
                         ?? options.first?.1 ?? "—")
                        .scaledFont(size: 11)
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(size: 9)
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }
}
