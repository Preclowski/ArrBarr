import os
import SwiftUI
import MediaKit

// MARK: - Hover tooltip

extension View {
    func libraryTooltip(entry: LibraryEntry, apiKey: String?) -> some View {
        hoverTooltip { LibraryEntryTooltip(entry: entry, apiKey: apiKey) }
    }
}

/// Library counterpart of `QueueItemTooltip`.
private struct LibraryEntryTooltip: View {
    let entry: LibraryEntry
    let apiKey: String?
    @Environment(ConfigStore.self) var configStore
    /// Radarr/Whisparr list endpoints don't compute custom formats, release group or languages;
    /// `/moviefile` does, and the clients cache it per movie.
    @State private var fileDetails: ArrFile?
    /// TMDB-only (see `CountryProvider`); fetching here warms the detail view's cache.
    @State private var countries: [String] = []
    @Environment(\.locale) private var locale

    var body: some View {
        MediaTooltipChrome(
            title: entry.title,
            year: entry.year,
            posterURL: entry.posterURL,
            posterRequiresAuth: apiKey != nil,
            apiKey: apiKey,
            posterSize: MediaTooltipChrome<EmptyView>.posterSize(for: entry.source),
            blurred: configStore.shouldBlurPoster(for: entry.source),
            fallbackSymbol: entry.source.symbol,
            contextChip: entry.releaseStatusText(locale: configStore.currentLocale).map { AnyView(StateChip(text: $0)) },
            statusChip: AnyView(LibraryStatusChip(entry: entry))
        ) {
            if !entry.genres.isEmpty {
                GenreChips(genres: entry.genres)
            }
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TooltipRatingPills(chips: ratingChips)
            TooltipInfoGrid(lines: infoLines)
            TooltipOverview(text: entry.overview)
            if entry.profileName != nil || !formats.isEmpty || formatScore != 0 {
                TooltipFlowLayout(spacing: 3) {
                    if let profile = entry.profileName {
                        ProfileChip(name: profile)
                    }
                    ForEach(formats, id: \.self) { TagChip(text: $0) }
                    if formatScore != 0 {
                        ScoreChip(score: formatScore)
                    }
                }
                .padding(.top, 2)
            }
            TooltipFileName(name: fileDetails?.relativePath ?? entry.fileName)
        }
        .task {
            switch entry.source {
            case .radarr:
                countries = await CountryProvider.movieCountries(
                    tmdbId: entry.externalId, configStore: configStore)
            case .sonarr:
                countries = await CountryProvider.seriesCountries(
                    tmdbId: nil, tvdbId: entry.externalId, configStore: configStore)
            case .lidarr, .whisparr:
                break
            }
        }
        .task {
            guard fileDetails == nil, entry.state == .complete else { return }
            switch entry.source {
            case .radarr:
                fileDetails = await Logger.extras.attempt("library file tooltip") { try await configStore.radarrClient.fetchMovieFile(movieId: entry.arrId) } ?? nil
            case .whisparr:
                fileDetails = await Logger.extras.attempt("library file tooltip") { try await configStore.whisparrClient.fetchMovieFile(movieId: entry.arrId) } ?? nil
            case .sonarr, .lidarr:
                break
            }
        }
    }

    private var formats: [String] {
        if let fetched = fileDetails?.customFormats, !fetched.isEmpty {
            return fetched.map(\.name)
        }
        return entry.customFormats
    }

    private var formatScore: Int {
        fileDetails?.customFormatScore ?? entry.customFormatScore
    }

    private var subtitle: String {
        var parts: [String] = []
        if let runtime = entry.runtime, runtime > 0 {
            parts.append(runtime.runtimeText)
        }
        if let cert = entry.certification, !cert.isEmpty {
            parts.append(cert)
        }
        parts.append(contentsOf: CountryProvider.displayNames(countries, locale: locale))
        return parts.joined(separator: " · ")
    }

    /// Unlinked: tooltips are hover chrome, not click targets.
    private var ratingChips: [RatingChip] {
        var chips: [RatingChip] = []
        switch entry.source {
        case .radarr, .whisparr:
            chips = [
                entry.ratingImdb.flatMap { RatingChip.imdb($0) },
                entry.ratingTmdb.flatMap { RatingChip.tmdb($0) },
                entry.ratingRt.flatMap { RatingChip.rottenTomatoes($0) },
                entry.ratingMetacritic.flatMap { RatingChip.metacritic($0) },
            ].compactMap { $0 }
        case .sonarr:
            chips = [entry.ratingArr.flatMap { RatingChip.tvdb($0) }].compactMap { $0 }
        case .lidarr:
            break
        }
        return chips
    }

    private var infoLines: [TooltipInfoLine] {
        var lines: [TooltipInfoLine] = []
        if let quality = entry.fileQuality {
            lines.append(TooltipInfoLine(labelKey: "Quality", value: quality))
        }
        if let total = entry.totalCount, total > 0 {
            lines.append(TooltipInfoLine(
                labelKey: entry.source == .lidarr ? "library.tracks.label" : "library.episodes.label",
                value: "\(entry.fileCount ?? 0)/\(total)"
            ))
        }
        if let size = entry.sizeText {
            lines.append(TooltipInfoLine(labelKey: "Size", value: size))
        }
        if let group = fileDetails?.releaseGroup, !group.isEmpty {
            lines.append(TooltipInfoLine(labelKey: "Release group", value: group))
        }
        if let languages = fileDetails?.languages?.compactMap(\.name), !languages.isEmpty {
            lines.append(TooltipInfoLine(labelKey: "Languages", value: languages.joined(separator: ", ")))
        }
        return lines
    }
}
