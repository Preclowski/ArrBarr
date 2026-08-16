import SwiftUI

public struct SearchAddPanel: View {
    /// Mutable so we can swap in an enriched copy when the source was a
    /// chat result built from a TMDB summary (no IMDB / RT / runtime).
    /// `+`-flow results already arrive enriched and the swap is a no-op.
    @State private var result: SearchResult
    var viewModel: SearchViewModel
    let onBack: () -> Void

    @ObservedObject private var storeManager = StoreManager.shared

    /// Identity of the title this panel was opened for, frozen at init.
    ///
    /// The cast / trailer tasks used to key on `result.id`, which enrichment
    /// *changes* for a TMDB-sourced series (0 → the resolved tvdbId). That
    /// re-ran both fetches mid-panel — the visible half of the wrong-series
    /// bug, since the second run was the one that repainted the strip. The
    /// panel shows one title for its whole life, so its task key is constant.
    private let identityKey: String

    public init(result: SearchResult, viewModel: SearchViewModel,
                onBack: @escaping () -> Void) {
        _result = State(initialValue: result)
        self.viewModel = viewModel
        self.onBack = onBack
        self.identityKey = result.id
    }

    /// Trailer for the title being added. Nil = no clip (or no TMDB key for
    /// the series route), and then no badge on the poster.
    @State private var trailerKey: String?
    /// The clip on screen, presented as a full-surface overlay.
    @State private var presentedTrailer: String?

    // Radarr state
    @State private var selectedProfileId: Int?
    @State private var selectedRootFolder: String?
    @State private var radarrMonitor: RadarrMonitorMode = .movieOnly

    // Sonarr state
    @State private var sonarrMonitor: SonarrMonitorMode = .all
    @State private var seriesType: SonarrSeriesType = .standard
    /// Season folders default to on for every series we add. The toggle
    /// used to live in the form but it was a power-user knob that almost
    /// nobody flipped — Sonarr's own default is the same. Constant `true`
    /// keeps the API call shape compatible without re-surfacing UI.
    private let seasonFolder = true

    // Lidarr state
    @State private var selectedMetadataProfileId: Int?

    // Whisparr state
    @State private var whisparrMonitor: RadarrMonitorMode = .movieOnly
    @State private var lidarrMonitor: LidarrMonitorMode = .all
    /// Poster lightbox — set to a URL when the user taps the hero
    /// poster, cleared by the xmark / scrim tap. Renders the shared
    /// `PosterLightbox` as a ZStack overlay so the focused view
    /// covers the entire popover (form + scroll).
    @State private var enlargedPoster: URL?

    @EnvironmentObject private var configStore: ConfigStore
    /// Cast for the "new title to download" detail — fetched from TMDB so the
    /// add panel matches the in-library DetailView (which also shows a CastRow).
    /// Movies/series only; empty until loaded (and stays empty without a TMDB key).
    @State private var cast: [CastMember] = []
    /// True while the TMDB credits fetch is in flight — drives the cast
    /// skeleton so the hero doesn't jump when the strip pops in.
    @State private var castLoading = false
    /// Cast-head tap → in-app person view, pushed locally so back returns
    /// here (same wiring as DetailView).
    @State private var personRef: PersonRef?

    public var body: some View {
        ZStack {
            mainContent
                // Parked while the lightbox is up, so the frosted scrim doesn't
                // blur a visible layout underneath. All four mechanisms, same
                // as PopoverContentView: hiding and un-clicking a layer still
                // leaves it holding pointer regions and sitting in the
                // accessibility tree. Full-bleed artwork makes that worse — the
                // poster now covers the window edge to edge, so anything
                // leaking from below leaks everywhere rather than in a margin.
                .opacity(enlargedPoster != nil ? 0 : 1)
                .allowsHitTesting(enlargedPoster == nil)
                .disabled(enlargedPoster != nil)
                .accessibilityHidden(enlargedPoster != nil)

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
        // No `.navigationTitle` here: the panel is a ZStack overlay inside the
        // root NavigationStack and draws its own `header` (title + FloatingBackButton),
        // so a navigationTitle would propagate up and render a SECOND, stacked
        // header above the real one.
        .personDestination($personRef)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header

            // Scrollable content — hero card + overview only. The
            // parameter form + Add CTA used to live in here at the
            // bottom of the scroll; the user reported having to scroll
            // past a tall overview just to find the action. Pinned
            // them to a sticky footer below so the CTA is always one
            // tap away.
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

            // Sticky footer — parameter form + glass CTA pinned to
            // the bottom of the popover. Thin material backdrop +
            // divider so the footer reads as a distinct surface
            // floating above the scroll content.
            VStack(spacing: 6) {
                if viewModel.isLoadingOptions {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
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
            .background(
                Rectangle()
                    .fill(.thinMaterial)
                    .overlay(alignment: .top) {
                        Divider().opacity(0.4)
                    }
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Enrich first so the hero card upgrades from TMDB-lean to
            // full-fat IMDB/RT/runtime as soon as possible. Runs in
            // parallel with loadOptions — they hit different endpoints.
            async let enrich: Void = {
                if needsEnrichment, let enriched = await viewModel.enrich(result) {
                    result = enriched
                }
            }()
            async let options: Void = viewModel.loadOptions(source: result.source)
            _ = await (enrich, options)
            selectedProfileId = viewModel.qualityProfiles.first?.id
            selectedRootFolder = viewModel.rootFolders.first?.path
            selectedMetadataProfileId = viewModel.metadataProfiles.first?.id
        }
        .task(id: identityKey) {
            // `addError` lives on the shared SearchViewModel, so a failed add
            // ("this movie has already been added") stuck around and rendered
            // under the form of the *next* title the user opened. Clear it
            // whenever a panel comes up for a title.
            viewModel.addError = nil
            await loadCast()
        }
        .task(id: identityKey) { await resolveTrailer() }
        // Deciding whether to ADD is when a trailer is worth most, so the panel
        // presents it exactly like the detail view does.
        .trailerOverlay(key: $presentedTrailer)
    }

    /// TMDB-sourced chat results carry only voteAverage + title + year + genres.
    /// Lookup-sourced `+` results carry IMDB / RT / Metacritic / runtime too.
    /// Use those richer fields' absence as the "this came from chat" signal.
    private var needsEnrichment: Bool {
        result.runtime == nil && result.imdb == nil
            && result.rottenTomatoes == nil && result.metacritic == nil
    }

    // MARK: - Header chrome (matches DetailView)

    private var header: some View {
        // SearchAddPanel is presented as an *overlay* (from the Add tab and
        // from chat rich cards), not a NavigationStack push, so there's no
        // system `<` chevron. Render our own leading back button + title —
        // without it the chat → "add new movie" flow had no way back (the
        // reported bug). Mirrors EpisodeDetailOverlay's floating header.
        HStack(spacing: 6) {
            FloatingBackButton(action: onBack)
                .keyboardShortcut(.cancelAction)
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

    private var trailerBadge: AnyView? {
        guard trailerKey != nil else { return nil }
        return AnyView(
            TrailerPosterBadge(isPlaying: presentedTrailer != nil) {
                withAnimation(.smooth(duration: 0.22)) {
                    presentedTrailer = presentedTrailer == nil ? trailerKey : nil
                }
            }
        )
    }

    /// `mediaRef` already knows which foreign key this result carries, so the
    /// movie/series split needs no second source check.
    private func resolveTrailer() async {
        presentedTrailer = nil
        trailerKey = nil
        switch result.mediaRef {
        case .tmdb(let id):
            trailerKey = await TrailerProvider.movieTrailerKey(
                radarrTrailerId: nil, tmdbId: id, configStore: configStore
            )
        case .tvdb(let id):
            // Same as the cast strip: pass the TMDB id when the row has one,
            // so this costs one request instead of a `/find` plus one.
            trailerKey = await TrailerProvider.seriesTrailerKey(
                tmdbId: result.tmdbTVId, tvdbId: id, configStore: configStore
            )
        case .tmdbTV(let id):
            // A row that hasn't been resolved to a tvdbId yet — TMDB is the
            // only side that knows this show, and it is the side serving the
            // clip anyway.
            trailerKey = await TrailerProvider.seriesTrailerKey(
                tmdbId: id, tvdbId: nil, configStore: configStore
            )
        case .musicBrainz, .imdb:
            break
        }
    }

    /// Toolbar title — "The Boys (2019)" / "Inception (2010)". Falls
    /// back to bare title when year is unknown.
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
                genres: result.genres,
                ratings: ratingChips,
                // Overview beside the poster — same right-column layout the
                // detail view gets from this shared card (it used to render
                // below the poster here, as a separate block).
                overview: result.overview,
                posterURL: result.posterURL,
                fallbackSymbol: result.source == .sonarr ? "tv" : (result.source == .lidarr ? "music.note" : (result.source == .whisparr ? "flame" : "film")),
                posterAspect: 2.0/3.0,
                onPosterTap: { url in
                    withAnimation(.smooth(duration: 0.22)) {
                        enlargedPoster = url ?? result.posterURL
                    }
                },
                posterBadge: trailerBadge,
                // Title + year live in the nav-bar title now; hero
                // hides its in-card title to avoid duplication —
                // matches DetailView's pattern.
                showTitle: false
            )
            // Overview lives inside the header card's right column now.
            // Cast strip with a skeleton while the TMDB fetch is in flight —
            // same fill-in-as-it-lands pattern as DetailView.
            if !cast.isEmpty {
                CastRow(cast: cast, onTapPerson: { member in
                    if let ref = PersonRef(castMember: member) { personRef = ref }
                })
            } else if castLoading {
                SkeletonCastRow()
            }
        }
    }

    /// Fetch the cast via the shared `CastProvider`. Supplementary — silent on
    /// failure / no key. The result's `id` carries the TMDB movie id for
    /// movies and the TVDB series id for series (see `SearchResult`), which is
    /// exactly what each cast path keys on — plus `tmdbTVId` for series, which
    /// TMDB can serve directly. Handing that over skips the `/find` hop the
    /// provider would otherwise make, and it is the only route that works at
    /// all for a TMDB-sourced row (whose tvdbId slot is still 0).
    private func loadCast() async {
        guard !configStore.tmdbApiKey.isEmpty else { return }
        castLoading = true
        defer { castLoading = false }
        switch result.source {
        case .radarr, .whisparr:
            cast = await CastProvider.movieCast(
                radarrMovieId: nil, tmdbId: result.externalId, configStore: configStore)
        case .sonarr:
            cast = await CastProvider.seriesCast(
                tmdbId: result.tmdbTVId, tvdbId: result.externalId, demoSeriesId: nil,
                configStore: configStore)
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
                           get: { selectedRootFolder ?? viewModel.rootFolders.first?.path ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: viewModel.rootFolders.map { ($0.path, $0.path) })

            // Monitor choice applies to a fresh ARTIST add. An album row
            // always monitors exactly that album (the artist is created
            // with `monitor: none`), so the picker would be a lie there.
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
        // Direct links where an id exists (imdbId; movie result.id IS the
        // TMDB id, series result.id the TVDB id) — site search otherwise.
        if let v = result.imdb, let chip = RatingChip.imdb(v, linkTitle: result.title, imdbId: result.imdbId) {
            chips.append(chip)
        }
        if let v = result.rating {
            let isSeries = result.source == .sonarr
            let url = isSeries
                ? RatingSiteLink.tvdbSeries(id: result.externalId, title: result.title)
                : RatingSiteLink.tmdbMovie(id: result.externalId, title: result.title)
            chips.append(RatingChip(label: isSeries ? "TVDB" : "TMDB",
                                    value: String(format: "%.1f", v), color: isSeries ? .blue : .teal,
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
                           get: { selectedRootFolder ?? viewModel.rootFolders.first?.path ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: viewModel.rootFolders.map { ($0.path, $0.path) })

            formPicker("search.monitor.button",
                       selection: $whisparrMonitor,
                       options: RadarrMonitorMode.allCases.map { ($0, $0.displayName) })
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
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
                           get: { selectedRootFolder ?? viewModel.rootFolders.first?.path ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: viewModel.rootFolders.map { ($0.path, $0.path) })

            formPicker("search.monitor.button",
                       selection: $radarrMonitor,
                       options: RadarrMonitorMode.allCases.map { ($0, $0.displayName) })
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    // MARK: - Sonarr form

    private var sonarrForm: some View {
        // Same picker-row stack as every other arr's form (radarr / whisparr
        // / lidarr) — monitor mode used to be a horizontal chip strip here,
        // the lone control of its kind across the four forms, so it's a
        // `formPicker` now too.
        VStack(spacing: 4) {
            formPicker("search.qualityProfile.button",
                       selection: Binding(
                           get: { selectedProfileId ?? viewModel.qualityProfiles.first?.id ?? 0 },
                           set: { selectedProfileId = $0 }
                       ),
                       options: viewModel.qualityProfiles.map { ($0.id, $0.name) })

            formPicker("search.rootFolder.button",
                       selection: Binding(
                           get: { selectedRootFolder ?? viewModel.rootFolders.first?.path ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: viewModel.rootFolders.map { ($0.path, $0.path) })

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

    /// Two CTAs instead of one, because "Add" used to *also* kick off an
    /// indexer search without saying so — the arr started downloading and the
    /// only hint was a queue row appearing later. Splitting it puts the choice
    /// in the user's hands and names it.
    ///
    /// "Add and search" is the prominent one: it's what the old single button
    /// did, and it stays the common intent (you searched for a title because
    /// you want it).
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
                      let folder = selectedRootFolder ?? viewModel.rootFolders.first?.path else { return }
                // Dispatch on the result's MediaRef rather than its
                // `.source` enum — same outcome, but the ref kind
                // makes the per-arr add-method choice the explicit
                // axis (a `.tvdb` ref can only become an addSeries
                // call; the type system pins it down). Whisparr +
                // Radarr both carry `.tmdb` refs, so the inner
                // source check stays to disambiguate the two movie-
                // ID-using arrs.
                switch result.mediaRef {
                case .tmdb where result.source == .whisparr:
                    await viewModel.addScene(result, qualityProfileId: pid,
                                            rootFolderPath: folder, monitor: whisparrMonitor,
                                            searchOnAdd: searchOnAdd)
                case .tmdb:
                    await viewModel.addMovie(result, qualityProfileId: pid,
                                            rootFolderPath: folder, monitor: radarrMonitor,
                                            searchOnAdd: searchOnAdd)
                // Not yet resolved to a tvdbId — `addSeries` does that by id
                // before it posts, and refuses if it can't.
                case .tvdb, .tmdbTV:
                    await viewModel.addSeries(result, qualityProfileId: pid,
                                             rootFolderPath: folder, monitor: sonarrMonitor,
                                             seriesType: seriesType, seasonFolder: seasonFolder,
                                             searchOnAdd: searchOnAdd)
                case .musicBrainz:
                    let metaPid = selectedMetadataProfileId ?? viewModel.metadataProfiles.first?.id ?? 1
                    if result.isLidarrAlbum {
                        // Album row: add just this album (artist gets created
                        // unmonitored-for-new so only this album is tracked).
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
                    // IMDB-only refs aren't directly addable — the search
                    // pipeline should have resolved them to tmdb/tvdb
                    // before reaching this UI. Log and bail.
                    viewModel.addError = "Unsupported reference type — IMDB IDs must be resolved before adding."
                }
                if viewModel.addError == nil {
                    // Surfaces to any deck showing this title — the Quiz drops
                    // the card instead of offering something already added.
                    LibraryAddCompletion.post(foreignId: result.foreignId)
                    onBack()
                }
            }
        } label: {
            Group {
                if viewModel.isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    // Catalog keys, not the English labels themselves: these
                    // used to be plain `String`s handed to `Text(_:)`, which
                    // resolves to the *non-localizing* StringProtocol overload,
                    // so the button read "Add to Radarr" in every language even
                    // though the translations were already sitting in the
                    // catalog under these very keys.
                    let addLabel: LocalizedStringKey = {
                        switch result.source {
                        case .radarr: return "search.addToRadarr.button"
                        case .sonarr: return "search.addToSonarr.button"
                        case .lidarr: return "search.addToLidarr.button"
                        case .whisparr: return "search.addToWhisparr.button"
                        }
                    }()
                    // Source glyph (film / tv / music.note / flame) leads
                    // the label — same visual that titles section headers
                    // and queue rows for this arr. Makes the CTA read at
                    // a glance which service it'll hit. The search variant
                    // trades it for a magnifier: the pair sits side by side
                    // under one hero, so which arr is already unambiguous and
                    // the glyph's job becomes telling the two buttons apart.
                    HStack(spacing: 6) {
                        if !storeManager.isPro {
                            Image(systemName: "lock.fill")
                        }
                        if searchOnAdd {
                            Image(systemName: "magnifyingglass")
                                .scaledFont(size: 11, weight: .semibold)
                            Text("search.addAndSearch.button", bundle: .module)
                                .scaledFont(size: 12, weight: .semibold)
                        } else {
                            ServiceIcon(source: result.source, size: 11)
                            Text(addLabel, bundle: .module)
                                .scaledFont(size: 12, weight: .semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        // Only the search variant is prominent — two filled buttons of equal
        // weight would make the user stop and read instead of reaching for the
        // one they almost always want.
        .modifier(AddCTAStyle(prominent: searchOnAdd))
        .disabled(viewModel.isAdding || viewModel.isLoadingOptions)
    }

    // MARK: - Helpers

    /// Prominent for the primary CTA, plain glass for the secondary — reuses
    /// the two shared button styles rather than inventing a third.
    private struct AddCTAStyle: ViewModifier {
        let prominent: Bool
        func body(content: Content) -> some View {
            if prominent {
                content.modifier(GlassProminentButtonStyle())
            } else {
                content.modifier(GlassButtonStyle())
            }
        }
    }

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
