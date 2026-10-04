import SwiftUI

extension DetailView {
    // MARK: - Content switch

    @ViewBuilder
    var content: some View {
        // No monolithic spinner: each section shows its own skeleton until its fetch lands.
            switch item.source {
            case .radarr, .whisparr:
                let titleFallback = splitTitleAndYear(item.title)
                let movieHeader = headerCard(
                    title: radarrDetail?.title ?? titleFallback.title,
                    year: radarrDetail?.year ?? titleFallback.year,
                    runtime: radarrDetail?.runtime,
                    genres: radarrDetail?.genres ?? [],
                    certification: radarrDetail?.certification,
                    ratings: movieRatingChipsFor(radarrDetail),
                    overview: radarrDetail?.overview,
                    existingTrailer: nil,
                    posterUrl: arrPosterURL(images: radarrDetail?.images, for: item, in: configStore,
                                     mediaServerKeys: radarrDetail?.mediaServerKeys ?? []),
                    fallbackSymbol: "film",
                    posterAspect: 2.0/3.0,
                    metadataLoading: loading,
                    titleBadge: movieTitleBadge
                )
                RadarrDetailPanel(
                    item: item,
                    radarrDetail: radarrDetail,
                    radarrMovieFile: radarrMovieFile,
                    siblings: siblings,
                    hasActiveDownloads: hasActiveDownloads,
                    loadError: loadError,
                    isLoading: loading,
                    header: movieHeader,
                    cast: cast,
                    onTapPerson: openPerson,
                    trailer: trailer,
                    arrWebURLForItem: { q in arrWebURL(for: q, in: configStore) },
                    onPauseItem: { q in Task { await viewModel.pause(q); await viewModel.refresh() } },
                    onResumeItem: { q in Task { await viewModel.resume(q); await viewModel.refresh() } },
                    onDeleteItem: { q in Task { await viewModel.delete(q) } }
                )
            case .sonarr:
                let titleFallback = splitTitleAndYear(item.title)
                let seriesHeader = headerCard(
                    title: sonarrDetail?.title ?? titleFallback.title,
                    year: sonarrDetail?.year ?? titleFallback.year,
                    runtime: sonarrDetail?.runtime,
                    genres: sonarrDetail?.genres ?? [],
                    certification: sonarrDetail?.network,
                    ratings: sonarrRatingChipsFor(sonarrDetail),
                    overview: sonarrDetail?.overview,
                    existingTrailer: nil,
                    posterUrl: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore,
                                              mediaServerKeys: sonarrDetail?.mediaServerKeys ?? []),
                    fallbackSymbol: "tv",
                    posterAspect: 2.0/3.0,
                    metadataLoading: loading,
                    // Any episode file on disk makes the series library-owned.
                    titleBadge: seriesTitleBadge,
                    // A series has no single director — TMDB's `created_by` answers the same question.
                    directedByKey: "detail.createdBy.label"
                )
                SonarrDetailPanel(
                    siblings: siblings,
                    loadError: loadError,
                    isLoading: loading,
                    header: seriesHeader,
                    cast: cast,
                    onTapPerson: openPerson,
                    trailer: trailer,
                    sonarrDetail: $sonarrDetail,
                    onTapSeason: { season in
                        seasonDrill = SeasonDrill(
                            seriesId: item.entityId ?? 0,
                            seasonNumber: season.seasonNumber,
                            seriesTitle: sonarrDetail?.title ?? titleFallback.title,
                            seriesYear: sonarrDetail?.year ?? titleFallback.year
                        )
                    },
                    onSetSeasonMonitored: { season, monitored in
                        await setSeasonMonitored(seasonNumber: season.seasonNumber, monitored: monitored)
                    },
                    onAutomaticSeasonSearch: { season in
                        try await configStore.sonarrClient.searchSeason(
                            seriesId: item.entityId ?? 0, seasonNumber: season.seasonNumber)
                    },
                    onManualSeasonSearch: { season in
                        manualSearchTarget = .season(
                            seriesId: item.entityId ?? 0,
                            seasonNumber: season.seasonNumber,
                            title: seasonSearchTitle(season.seasonNumber))
                    },
                    nextEpisode: nextEpisode,
                    posterURL: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore,
                                            mediaServerKeys: sonarrDetail?.mediaServerKeys ?? []) ?? item.posterURL,
                    posterRequiresAuth: item.posterRequiresAuth,
                    posterAPIKey: configStore.sonarr.apiKey
                )
            case .lidarr:
                LidarrDetailPanel(
                    item: item,
                    lidarrAlbum: lidarrAlbum,
                    lidarrTracks: lidarrTracks,
                    lidarrTrackFiles: lidarrTrackFiles,
                    siblings: siblings,
                    hasActiveDownloads: hasActiveDownloads,
                    loadError: loadError,
                    isLoading: loading,
                    enlargedPoster: $enlargedPoster,
                    selectedDiscNumber: $selectedDiscNumber,
                    arrWebURLForItem: { q in arrWebURL(for: q, in: configStore) },
                    onPauseItem: { q in Task { await viewModel.pause(q); await viewModel.refresh() } },
                    onResumeItem: { q in Task { await viewModel.resume(q); await viewModel.refresh() } },
                    onDeleteItem: { q in Task { await viewModel.delete(q) } },
                    posterCornerAction: monitorPosterToggle,
                    onOpenArtist: { artist in
                        guard let artistId = artist.id, let name = artist.artistName else { return }
                        artistDrill = DetailRequest.syntheticArtistItem(
                            artistId: artistId,
                            name: name,
                            posterURL: arrPosterURL(images: artist.images, for: item, in: configStore),
                            posterRequiresAuth: item.posterRequiresAuth
                        )
                    }
                )
            }
    }

    /// Release status is a fact of the title, so it sits here, not in the file banner.
    private var movieTitleBadge: AnyView? {
        let release = ArrReleaseStatusLabel.text(radarrDetail?.status, locale: configStore.currentLocale)
        // Nothing until the detail lands — a bare "Missing" mid-fetch would be a claim we can't back.
        guard radarrDetail != nil || qualityProfileName != nil else { return nil }
        // Profile first, matching the series hero.
        return AnyView(HStack(spacing: 4) {
            if let profile = qualityProfileName { ProfileChip(name: profile) }
            if let release { StateChip(text: release) }
            // "Downloaded" is the poster's bottom strip.
            if radarrDetail != nil, movieFileState != .complete {
                MediaStateChip(state: movieFileState, locale: configStore.currentLocale)
            }
        })
    }

    private var movieFileState: LibraryEntry.FileState {
        .movie(monitored: radarrDetail?.monitored,
               hasFile: (radarrMovieFile ?? radarrDetail?.movieFile) != nil)
    }

    /// Series hero's title badges — assigned profile + how much is on disk.
    private var seriesTitleBadge: AnyView? {
        guard sonarrDetail != nil || qualityProfileName != nil else { return nil }
        return AnyView(HStack(spacing: 4) {
            if let profile = qualityProfileName { ProfileChip(name: profile) }
            if sonarrDetail?.status?.lowercased() == "ended",
               let ended = ArrReleaseStatusLabel.text("ended", locale: configStore.currentLocale) {
                // Brown: a fact, not a problem; green/orange/red/blue are file states, indigo is upgrade.
                StateChip(text: ended, color: .brown)
            }
            // No have/total: the season rows carry the actionable count, and a partial series has
            // nothing to say in one word. "Downloaded" is the poster's bottom strip.
            if sonarrDetail != nil, seriesFileState != .partial, seriesFileState != .complete {
                MediaStateChip(state: seriesFileState, locale: configStore.currentLocale)
            }
        })
    }

    /// From the season statistics, matching the Library tab; counting `sonarrEpisodes` would
    /// call every ongoing series half-missing (unaired episodes are listed too).
    private var seriesEpisodeCounts: EpisodeFileCounts {
        sonarrDetail?.episodeFileCounts ?? EpisodeFileCounts(have: 0, total: 0)
    }

    private var seriesFileState: LibraryEntry.FileState {
        .series(monitored: sonarrDetail?.monitored, counts: seriesEpisodeCounts)
    }

    /// Nothing until the record lands, like the chips.
    var heroLibraryMark: LibraryMark? {
        if radarrDetail != nil { return LibraryMark(downloaded: movieFileState == .complete) }
        if sonarrDetail != nil { return LibraryMark(downloaded: seriesFileState == .complete) }
        return nil
    }
}
