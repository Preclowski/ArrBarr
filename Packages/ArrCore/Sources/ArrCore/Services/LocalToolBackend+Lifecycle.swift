import os
import Foundation
import MediaKit

extension LocalToolBackend {
    // MARK: - Monitor + search

    /// Enabling always fires a SeasonSearch: with an opt-out the model defaulted it off and still
    /// claimed "search queued". The result reports each step's real outcome.
    func sonarrMonitorSeason(_ args: JSONValue) async throws -> ToolCallOutput {
        let seriesId = Self.intArg(args, key: "seriesId")
        // Chat requests often name several seasons; SeasonSearch is per-season, so one call each.
        var seasons = Self.intArrayArg(args, key: "seasonNumbers")
        if seasons.isEmpty, let single = Self.optionalIntArg(args, key: "seasonNumber") {
            seasons = [single]
        }
        seasons = Array(Set(seasons)).sorted()
        guard !seasons.isEmpty else {
            return ToolCallOutput(text: "Need seasonNumbers (non-empty integer array) or a single seasonNumber.")
        }
        let state = Self.optionalBoolArg(args, key: "state") ?? true
        guard seriesId > 0 else {
            return ToolCallOutput(text: "Need a valid seriesId — run sonarr_get_series to resolve it.")
        }
        guard sonarr.isConfigured else {
            return ToolCallOutput(text: "Sonarr is not configured.")
        }
        let client = sonarrClient

        func list(_ xs: [Int]) -> String { xs.map(String.init).joined(separator: ", ") }

        // A single rejected season doesn't sink the rest.
        var monitored: [Int] = []
        var monitorFailed: [Int] = []
        var lastMonitorError = ""
        for s in seasons {
            do {
                try await client.setSeasonMonitored(seriesId: seriesId, seasonNumber: s, monitored: state)
                monitored.append(s)
            } catch {
                monitorFailed.append(s)
                lastMonitorError = error.localizedDescription
            }
        }

        guard state else {
            if monitorFailed.isEmpty {
                return ToolCallOutput(text: "OK: stopped monitoring season(s) \(list(monitored)) of seriesId=\(seriesId). No search triggered.")
            }
            if monitored.isEmpty {
                return ToolCallOutput(text: "FAILED to stop monitoring season(s) \(list(monitorFailed)): \(lastMonitorError).")
            }
            return ToolCallOutput(text: "PARTIAL: stopped monitoring season(s) \(list(monitored)); FAILED for \(list(monitorFailed)) (\(lastMonitorError)). No search triggered.")
        }

        // Report the per-season outcome so the model can't paper over a partial failure.
        var searched: [Int] = []
        var searchFailed: [Int] = []
        var lastSearchError = ""
        for s in monitored {
            do {
                try await client.searchSeason(seriesId: seriesId, seasonNumber: s)
                searched.append(s)
            } catch {
                searchFailed.append(s)
                lastSearchError = error.localizedDescription
            }
        }

        if monitorFailed.isEmpty && searchFailed.isEmpty {
            return ToolCallOutput(text: "OK: season(s) \(list(searched)) of seriesId=\(seriesId) now monitored, and a SeasonSearch command was POST'd to Sonarr for each. Indexer results will land in the queue when releases match — typically within ~30 seconds, longer if indexers are slow.")
        }

        var parts: [String] = []
        if !searched.isEmpty { parts.append("monitored + searching season(s) \(list(searched))") }
        if !searchFailed.isEmpty { parts.append("monitored but Sonarr REJECTED the search for season(s) \(list(searchFailed)) (\(lastSearchError))") }
        if !monitorFailed.isEmpty { parts.append("FAILED to even monitor season(s) \(list(monitorFailed)) (\(lastMonitorError))") }
        return ToolCallOutput(text: "PARTIAL: " + parts.joined(separator: "; ") + ". Tell the user EXACTLY which seasons worked and which didn't — do not claim full success. For rejected searches they should retry shortly or use the season's search button in DetailView. DO NOT call sonarr_search_episodes as a workaround — it grabs per-episode releases instead of a season pack.")
    }

    func sonarrSearchEpisodesTool(_ args: JSONValue) async throws -> ToolCallOutput {
        let ids = Self.intArrayArg(args, key: "episodeIds")
        guard !ids.isEmpty else {
            return ToolCallOutput(text: "Need episodeIds (non-empty integer array).")
        }
        guard sonarr.isConfigured else {
            return ToolCallOutput(text: "Sonarr is not configured.")
        }
        do {
            try await sonarrClient.searchEpisodes(episodeIds: ids)
            return ToolCallOutput(text: "Queued search for \(ids.count) episode\(ids.count == 1 ? "" : "s").")
        } catch {
            return ToolCallOutput(text: "Couldn't queue search: \(error.localizedDescription)")
        }
    }

    /// Radarr's monitored flag isn't changed.
    func radarrSearchMovieTool(_ args: JSONValue) async throws -> ToolCallOutput {
        let movieId = Self.intArg(args, key: "movieId")
        guard movieId > 0 else {
            return ToolCallOutput(text: "Need a valid movieId — run radarr_get_movies to resolve it.")
        }
        guard radarr.isConfigured else {
            return ToolCallOutput(text: "Radarr is not configured.")
        }
        // Radarr answers 200 to a MoviesSearch for an unknown id, so validate first. A tmdbId in the
        // movieId slot that maps to an owned movie is corrected silently.
        let movies = await LibraryIndex.shared.movies(config: radarr)
        let resolvedId: Int
        let title: String
        if let hit = movies.first(where: { $0.id == movieId }) {
            resolvedId = movieId
            title = hit.title
        } else if let byTmdb = movies.first(where: { $0.tmdbId == movieId }), let realId = byTmdb.id {
            resolvedId = realId
            title = byTmdb.title
        } else {
            return ToolCallOutput(text: "movieId \(movieId) is NOT in the Radarr library, so there is nothing to search for. This tool only re-runs the indexer search for movies the user ALREADY has. There is NO tool that adds a movie — adding happens when the USER taps a card from radarr_search and confirms in the add panel. If they asked to add this title, tell them to tap its card.")
        }
        do {
            try await radarrClient.searchMovie(movieId: resolvedId)
            return ToolCallOutput(text: "Search queued for \(title) (movieId \(resolvedId)). Indexers will report back into the regular queue.")
        } catch {
            return ToolCallOutput(text: "Couldn't queue search: \(error.localizedDescription)")
        }
    }

    /// Capped to 40 albums; a trailing note tells the model how many were dropped.
    func lidarrGetArtistAlbums(_ args: JSONValue) async throws -> ToolCallOutput {
        let artistId = Self.intArg(args, key: "artistId")
        guard artistId > 0 else {
            return ToolCallOutput(text: "Need a valid artistId — run lidarr_get_artists to resolve it.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        let typeFilter = Self.stringArg(args, key: "albumType").lowercased()
        let albums: [ArrAlbum]
        do {
            albums = try await lidarrClient.fetchArtistAlbums(artistId: artistId)
        } catch {
            return ToolCallOutput(text: "Lidarr fetch failed: \(error.localizedDescription)")
        }
        let filtered = albums.filter { rec in
            guard !typeFilter.isEmpty else { return true }
            return (rec.albumType ?? "").lowercased() == typeFilter
        }
        guard !filtered.isEmpty else {
            return ToolCallOutput(text: typeFilter.isEmpty
                ? "No albums found for artistId=\(artistId)."
                : "No \(typeFilter) albums found for artistId=\(artistId).")
        }
        let cap = 40
        let shown = filtered.prefix(cap)
        let lines = shown.map { rec -> String in
            let year = Self.yearFromReleaseDate(rec.releaseDate)
            let typePart = rec.albumType.map { " · \($0)" } ?? ""
            let yearPart = year.map { " (\($0))" } ?? ""
            let mon = (rec.monitored ?? false) ? "✓" : "✗"
            let have = rec.statistics?.trackFileCount ?? 0
            let total = rec.statistics?.totalTrackCount ?? rec.statistics?.trackCount ?? 0
            return "• albumId=\(rec.id.map(String.init) ?? "?") · \(rec.title)\(yearPart)\(typePart) · \(mon) \(have)/\(total) tracks"
        }
        // Name the artist: an id-only header gives the model no way to notice a wrong id.
        let name = await artistName(id: artistId)
        let who = name.map { "\($0) (artistId=\(artistId))" } ?? "artistId=\(artistId)"
        var out = "\(who) has \(filtered.count) album\(filtered.count == 1 ? "" : "s")"
        if !typeFilter.isEmpty { out += " (type=\(typeFilter))" }
        out += ":\n" + lines.joined(separator: "\n")
        if filtered.count > cap {
            out += "\n(\(filtered.count - cap) more not shown — narrow with albumType to see them all.)"
        }
        // Covers come from Lidarr, so the shown slice is what the rail renders — no second fetch.
        let cards = shown.compactMap { rec in
            rec.id.map { id in ChatAlbum(
                id: id,
                title: rec.title,
                year: Self.yearFromReleaseDate(rec.releaseDate),
                monitored: rec.monitored ?? false,
                trackFileCount: rec.statistics?.trackFileCount ?? 0,
                trackCount: rec.statistics?.totalTrackCount ?? rec.statistics?.trackCount ?? 0,
                images: rec.images ?? []
            ) }
        }
        return ToolCallOutput(text: out, rich: .albums(artist: name, albums: Array(cards)))
    }

    private func artistName(id: Int) async -> String? {
        guard let artists = await Logger.extras.attempt("lidarr artists", { try await lidarrClient.fetchAllArtists() }) else { return nil }
        return artists.first { $0.id == id }?.artistName
    }

    nonisolated static func yearFromReleaseDate(_ raw: String?) -> Int? {
        guard let raw, raw.count >= 4 else { return nil }
        return Int(raw.prefix(4))
    }

    /// Like `sonarrMonitorSeason`, state=true always fires the search.
    func lidarrMonitorAlbum(_ args: JSONValue) async throws -> ToolCallOutput {
        let albumId = Self.intArg(args, key: "albumId")
        guard albumId > 0 else {
            return ToolCallOutput(text: "Need a valid albumId — run lidarr_get_artist_albums to resolve it.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        let state = Self.optionalBoolArg(args, key: "state") ?? true
        let client = lidarrClient
        do {
            try await client.setAlbumMonitored(albumId: albumId, monitored: state)
        } catch {
            return ToolCallOutput(text: "FAILED to update monitoring: \(error.localizedDescription)")
        }
        guard state else {
            return ToolCallOutput(text: "OK: stopped monitoring albumId=\(albumId). No search triggered.")
        }
        do {
            try await client.searchAlbum(albumId: albumId)
            return ToolCallOutput(text: "OK: albumId=\(albumId) is now monitored, and AlbumSearch command was POST'd to Lidarr. Indexer results will land in the queue when releases match.")
        } catch {
            return ToolCallOutput(text: "PARTIAL: monitoring on, but search FAILED: \(error.localizedDescription). Tell the user the album is monitored but they need to manually search.")
        }
    }

    func lidarrSearchAlbumTool(_ args: JSONValue) async throws -> ToolCallOutput {
        let albumId = Self.intArg(args, key: "albumId")
        guard albumId > 0 else {
            return ToolCallOutput(text: "Need a valid albumId.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        do {
            try await lidarrClient.searchAlbum(albumId: albumId)
            return ToolCallOutput(text: "Search queued for album \(albumId).")
        } catch {
            return ToolCallOutput(text: "Couldn't queue search: \(error.localizedDescription)")
        }
    }
}
