import Foundation
import MediaKit

/// Wire records → ArrCore compositions. One function per shape for all four arr flavours.
nonisolated enum ArrCompositions {
    struct EntityMeta: Sendable {
        var title: String
        var secondary: String?
        var year: Int?
        var slug: String?
        var poster: URL?
        var posterRequiresAuth = false
        var mediaServerKeys: [MediaServerExternalKey] = []
    }

    // MARK: - Queue

    static func queueItem(_ r: ArrQueueRecord, source: QueueItem.Source, baseURL: String, files: [Int: [MediaKit.ArrFile]],
                          meta: [Int: EntityMeta], seasonPoster: URL? = nil) -> QueueItem {
        let total = clampedBytes(r.size)
        let left = clampedBytes(r.sizeleft)
        let progress = total > 0 ? max(0, min(1, 1.0 - Double(left) / Double(total))) : 0.0
        let entityID = entityID(of: r, source: source)
        let cached = entityID.flatMap { meta[$0] }

        var title = r.title ?? unknownTitle
        var subtitle: String?
        var seasonNumber: Int?, episodeNumber: Int?, episodeTitle: String?
        var poster = cached?.poster
        var posterAuth = cached?.posterRequiresAuth ?? false
        var slug = cached?.slug
        var existing: [MediaKit.ArrFile] = entityID.flatMap { files[$0] } ?? []

        switch source {
        case .radarr, .whisparr:
            if let c = cached { title = c.year.map { "\(c.title) (\($0))" } ?? c.title }
            else if let m = r.movie { title = m.year.map { "\(m.title) (\($0))" } ?? m.title }
            if poster == nil { (poster, posterAuth) = (r.movie?.images ?? []).posterURL(baseURL: baseURL, mediaServerKeys: source == .radarr ? r.movie?.mediaServerKeys ?? [] : []) }
            slug = slug ?? r.movie?.titleSlug
            if existing.isEmpty, let file = r.movie?.movieFile { existing = [file] }
        case .sonarr:
            let seriesTitle = cached?.title ?? r.series?.title
            let year = cached?.year ?? r.series?.year
            if let seriesTitle {
                title = year.map { "\(seriesTitle) (\($0))" } ?? seriesTitle
                if let ep = r.episode, let s = ep.seasonNumber, let n = ep.episodeNumber {
                    seasonNumber = s; episodeNumber = n
                    episodeTitle = ep.title?.isEmpty == false ? ep.title : nil
                    subtitle = EpisodeCode.line(season: s, episode: n, title: episodeTitle)
                }
            }
            if poster == nil { (poster, posterAuth) = (r.series?.images ?? []).posterURL(baseURL: baseURL, mediaServerKeys: r.series?.mediaServerKeys ?? []) }
            if let seasonPoster { poster = seasonPoster; posterAuth = false }
            slug = slug ?? r.series?.titleSlug
            // Episode files are keyed by series; the upgrade comparison wants this episode's file.
            let fileID = r.episode?.episodeFileId ?? 0
            existing = fileID > 0 ? existing.filter { $0.id == fileID } : []
        case .lidarr:
            let artist = cached?.secondary ?? r.artist?.artistName ?? r.album?.artist?.artistName
            let album = cached?.title ?? r.album?.title ?? r.title ?? unknownTitle
            title = artist.map { "\($0) — \(album)" } ?? album
            if poster == nil { (poster, posterAuth) = [ArrImage].lidarrCover(album: r.album?.images, artist: r.artist?.images, baseURL: baseURL) }
            slug = slug ?? r.album?.foreignAlbumId
        }

        // Same ids the artwork override keys on: the cached meta when the
        // loader resolved the entity, the wire record otherwise.
        let mediaServerKeys: [MediaServerExternalKey] = {
            if let cached, !cached.mediaServerKeys.isEmpty { return cached.mediaServerKeys }
            switch source {
            case .radarr: return r.movie?.mediaServerKeys ?? []
            case .sonarr: return r.series?.mediaServerKeys ?? []
            case .whisparr, .lidarr: return []
            }
        }()

        let representative = source == .lidarr ? existing.max { ($0.size ?? 0) < ($1.size ?? 0) } : existing.first
        let existingSize: Int64? = source == .lidarr
            ? (existing.reduce(Int64(0)) { $0 + ($1.size ?? 0) }).nonZero
            : representative?.size
        let isUpgrade = !existing.isEmpty || (r.movie?.hasFile ?? false) || (r.episode?.hasFile ?? false)

        return QueueItem(
            id: "\(source.rawValue)-\(r.id)",
            source: source,
            arrQueueId: r.id,
            downloadId: r.downloadId,
            downloadProtocol: parseProtocol(r.protocol),
            downloadClient: r.downloadClient,
            indexer: r.indexer,
            title: title,
            subtitle: subtitle,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            episodeTitle: episodeTitle,
            releaseName: r.title,
            status: parseStatus(arrStatus: r.status, trackedState: r.trackedDownloadState, trackedStatus: r.trackedDownloadStatus),
            progress: progress,
            sizeTotal: total,
            sizeLeft: left,
            timeLeft: r.timeleft,
            customFormats: (r.customFormats ?? []).map(\.name),
            customFormatScore: r.customFormatScore ?? 0,
            quality: r.quality?.name,
            releaseGroup: source == .sonarr ? parseReleaseGroup(from: r.title) : nil,
            isUpgrade: isUpgrade,
            existingCustomFormats: (representative?.customFormats ?? []).map(\.name),
            existingCustomFormatScore: representative?.customFormatScore,
            existingQuality: representative?.quality?.name,
            existingSize: existingSize,
            existingFileName: source == .lidarr ? nil : representative?.relativePath.map { URL(fileURLWithPath: $0).lastPathComponent },
            contentSlug: slug,
            entityId: entityID,
            posterURL: poster,
            posterRequiresAuth: posterAuth,
            // Per episode for Sonarr rows, per title for the rest (the
            // coordinates are nil there and the lookup falls back).
            watched: MediaServerIndex.shared.isWatched(mediaServerKeys, season: seasonNumber, episode: episodeNumber),
            statusMessages: flatten(r.statusMessages)
        )
    }

    static func entityID(of r: ArrQueueRecord, source: QueueItem.Source) -> Int? {
        switch source {
        case .radarr, .whisparr: r.movieId ?? r.movie?.id
        case .sonarr: r.seriesId ?? r.series?.id
        case .lidarr: r.albumId ?? r.album?.id
        }
    }

    /// Multi-row downloads of one season get the season poster; mirrors the old `seasonPackSeasons`.
    static func seasonPackSeasons(_ records: [ArrQueueRecord]) -> [String: Int] {
        var seasons: [String: Set<Int>] = [:]
        var rows: [String: Int] = [:]
        for r in records {
            guard let id = r.downloadId, !id.isEmpty, let season = r.episode?.seasonNumber ?? r.seasonNumber else { continue }
            seasons[id, default: []].insert(season)
            rows[id, default: 0] += 1
        }
        return seasons.compactMapValues { $0.count == 1 ? $0.first : nil }.filter { rows[$0.key, default: 0] > 1 }
    }

    // MARK: - Calendar

    static func upcoming(_ r: ArrCalendarRecord, source: QueueItem.Source, baseURL: String) -> UpcomingItem? {
        switch source {
        case .radarr, .whisparr:
            let (dateStr, releaseType): (String?, String) =
                if r.digitalRelease != nil { (r.digitalRelease, "Digital") }
                else if r.physicalRelease != nil { (r.physicalRelease, "Physical") }
                else { (r.inCinemas, "In Cinemas") }
            guard let dateStr, let date = parseArrDate(dateStr) else { return nil }
            let base = r.title ?? unknownTitle
            let keys: [MediaServerExternalKey] = source == .radarr ? (r.tmdbId.flatMap { $0 > 0 ? [.tmdbMovie($0)] : nil } ?? []) : []
            let (poster, auth) = (r.images ?? []).posterURL(baseURL: baseURL, mediaServerKeys: keys)
            return UpcomingItem(
                id: "\(source.rawValue)-cal-\(r.id)", source: source, title: r.year.map { "\(base) (\($0))" } ?? base, subtitle: nil,
                airDate: date, releaseType: releaseType, hasFile: r.hasFile ?? false, overview: r.overview,
                posterURL: poster, posterRequiresAuth: auth, imdb: r.ratings?.imdb?.value, tmdb: r.ratings?.tmdb?.value, runtime: r.runtime,
                entityId: r.id, genres: r.genres ?? [], certification: r.certification, releaseStatus: r.status,
                ratingRt: r.ratings?.rottenTomatoes?.value, ratingMetacritic: r.ratings?.metacritic?.value, qualityProfileId: r.qualityProfileId,
                tmdbId: source == .radarr ? r.tmdbId : nil)
        case .sonarr:
            guard let dateStr = r.airDateUtc, let date = parseArrDate(dateStr) else { return nil }
            let base = r.series?.title ?? unknownTitle
            var subtitle: String?
            if let s = r.seasonNumber, let e = r.episodeNumber {
                subtitle = EpisodeCode.line(season: s, episode: e, title: r.title)
            }
            let (poster, auth) = (r.series?.images ?? []).posterURL(baseURL: baseURL, mediaServerKeys: r.series?.mediaServerKeys ?? [])
            return UpcomingItem(
                id: "sonarr-cal-\(r.id)", source: .sonarr, title: r.series?.year.map { "\(base) (\($0))" } ?? base, subtitle: subtitle,
                airDate: date, releaseType: "Airing", hasFile: r.hasFile ?? false, overview: r.overview,
                posterURL: poster, posterRequiresAuth: auth, imdb: r.series?.ratings?.value, runtime: r.series?.runtime,
                entityId: r.seriesId, episodeFileId: r.episodeFileId, genres: r.series?.genres ?? [], releaseStatus: r.series?.status,
                qualityProfileId: r.series?.qualityProfileId, seasonNumber: r.seasonNumber, episodeNumber: r.episodeNumber, tvdbId: r.series?.tvdbId)
        case .lidarr:
            guard let dateStr = r.releaseDate, let date = parseArrDate(dateStr) else { return nil }
            let album = r.title ?? unknownTitle
            let (poster, auth) = [ArrImage].lidarrCover(album: r.images, artist: r.artist?.images, baseURL: baseURL)
            let tracks = r.statistics?.trackCount ?? 0, trackFiles = r.statistics?.trackFileCount ?? 0
            return UpcomingItem(
                id: "lidarr-cal-\(r.id)", source: .lidarr, title: r.artist?.artistName.map { "\($0) — \(album)" } ?? album, subtitle: nil,
                airDate: date, releaseType: "Album", hasFile: tracks > 0 && trackFiles >= tracks, overview: r.overview,
                posterURL: poster, posterRequiresAuth: auth, entityId: r.id, trackCount: tracks > 0 ? tracks : nil)
        }
    }

    // MARK: - History

    static func history(_ r: ArrHistoryRecord, source: QueueItem.Source, baseURL: String) -> HistoryItem? {
        guard let dateStr = r.date, let date = parseArrDate(dateStr) else { return nil }
        let eventType = HistoryItem.EventType.parse(r.eventType)
        let data = r.data
        var title = r.sourceTitle ?? unknownTitle
        var subtitle: String?
        var groupHint: HistoryItem.GroupHint?
        var poster: URL?, auth = false
        var arrId: Int?, fileKey: String?
        var fileOnDisk: HistoryItem.FileSnapshot?, hadFile: Bool?
        switch source {
        case .radarr, .whisparr:
            title = r.movie?.title ?? title
            (poster, auth) = (r.movie?.images ?? []).posterURL(baseURL: baseURL, mediaServerKeys: source == .radarr ? r.movie?.mediaServerKeys ?? [] : [])
            arrId = r.movieId ?? r.movie?.id
            fileKey = arrId.map { "movie-\($0)" }
            fileOnDisk = r.movie?.movieFile.map(snapshot)
            hadFile = r.movie?.hasFile
        case .sonarr:
            title = r.series?.title ?? title
            if let ep = r.episode, let s = ep.seasonNumber, let e = ep.episodeNumber {
                subtitle = EpisodeCode.line(season: s, episode: e, title: ep.title)
                if eventType == .imported || eventType == .grabbed, let batch = r.downloadId ?? r.sourceTitle {
                    groupHint = .init(key: "\(batch)|s\(s)", collapsedSubtitle: String(format: String(localized: "detail.seasonLld.label", bundle: .module), s))
                }
            }
            (poster, auth) = (r.series?.images ?? []).posterURL(baseURL: baseURL, mediaServerKeys: r.series?.mediaServerKeys ?? [])
            arrId = r.seriesId ?? r.series?.id
            fileKey = (r.episodeId ?? r.episode?.id).map { "episode-\($0)" }
            hadFile = r.episode?.hasFile
        case .lidarr:
            title = r.artist?.artistName ?? title
            subtitle = r.album?.title
            if eventType == .imported, let albumId = r.albumId, let batch = r.downloadId ?? r.sourceTitle {
                groupHint = .init(key: "\(batch)|album-\(albumId)")
            }
            (poster, auth) = [ArrImage].lidarrCover(album: r.album?.images, artist: r.artist?.images, baseURL: baseURL)
            arrId = r.artistId ?? r.artist?.id
        }
        return HistoryItem(
            id: "\(source.rawValue)-h-\(r.id)", source: source, date: date, eventType: eventType, title: title, subtitle: subtitle,
            sourceTitle: r.sourceTitle, quality: r.quality?.name, customFormats: (r.customFormats ?? []).map(\.name),
            customFormatScore: r.customFormatScore ?? 0, groupHint: groupHint, posterURL: poster, posterRequiresAuth: auth,
            arrId: arrId, fileKey: fileKey, downloadId: r.downloadId,
            downloadClient: text(data, "downloadClientName") ?? text(data, "downloadClient"),
            indexer: text(data, "indexer"), size: text(data, "size").flatMap { Int64($0) },
            deleteReason: text(data, "reason"), fileOnDisk: fileOnDisk, hadFileOnDisk: hadFile)
    }

    // MARK: - Helpers

    /// History `data` values arrive as strings or numbers depending on the arr version.
    static func text(_ data: [String: JSONValue]?, _ key: String) -> String? {
        switch data?[key] {
        case let .string(s)?: return s.isEmpty ? nil : s
        case let .number(n)?: return String(Int64(n))
        default: return nil
        }
    }

    static func snapshot(_ file: MediaKit.ArrFile) -> HistoryItem.FileSnapshot {
        HistoryItem.FileSnapshot(quality: file.quality?.name, score: file.customFormatScore, size: file.size,
                                 formats: (file.customFormats ?? []).map(\.name), filename: file.relativePath)
    }

    static func flatten(_ messages: [MediaKit.ArrStatusMessage]?) -> [String] {
        var out: [String] = []
        for entry in messages ?? [] {
            let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = (entry.messages ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if lines.isEmpty { if let title, !title.isEmpty { out.append(title) } }
            else { let prefix = (title?.isEmpty == false) ? "\(title!): " : ""; out += lines.map { prefix + $0 } }
        }
        return out
    }

    static func parseReleaseGroup(from name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        var stripped = name
        if let dot = stripped.lastIndex(of: ".") {
            let ext = stripped[stripped.index(after: dot)...]
            if ext.count <= 4, ext.allSatisfy({ $0.isLetter || $0.isNumber }) { stripped = String(stripped[..<dot]) }
        }
        guard let dash = stripped.lastIndex(of: "-") else { return nil }
        let token = stripped[stripped.index(after: dash)...]
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return String(token)
    }
}

nonisolated extension Int64 {
    fileprivate var nonZero: Int64? { self > 0 ? self : nil }
}

/// The user-facing text for a MediaKit failure; the arr's own reason wins when it sent one.
nonisolated enum MediaKitErrorPresenter {
    static func message(for error: MediaKitError) -> String {
        let server = error.serverMessage.flatMap { $0.isEmpty ? nil : $0 }
        // Servarr answers a bad key with an empty body; name the fix either way, and keep what a client did say.
        if case let .unauthorized(_, status, _) = error {
            let hint = text("mediakit.error.unauthorized", String(status))
            return server.map { "\(hint) (\($0))" } ?? hint
        }
        if let server { return server }
        switch error {
        // Name the service, not the app: "qBittorrent is not configured" is
        // the sentence the user can act on.
        case let .notConfigured(instance):
            guard let kind = ServiceKind(rawValue: instance.kind.rawValue) else {
                return String(localized: "common.arrbarrIsNotConfigured.label", bundle: .module)
            }
            return text("mediakit.error.notConfigured", kind.displayName)
        case let .unreachable(host, _): return text("mediakit.error.unreachable", host.description)
        case let .breakerOpen(host, _): return text("mediakit.error.breakerOpen", host.description)
        case let .rateLimited(host, _): return text("mediakit.error.rateLimited", host.description)
        case let .unauthorized(_, status, _): return text("mediakit.error.unauthorized", String(status))
        case let .rejected(_, status, _): return text("mediakit.error.rejected", String(status))
        case let .serverFault(_, status, _): return text("mediakit.error.serverFault", String(status))
        case let .serviceError(_, code, _): return text("mediakit.error.serviceError", code ?? "")
        case let .decoding(op, detail): return text("mediakit.error.decoding", op.name, detail)
        case let .unsupported(_, capability): return text("mediakit.error.unsupported", capability.rawValue)
        case let .persistence(detail): return text("mediakit.error.persistence", detail)
        case .notPermitted: return text("mediakit.error.notPermitted")
        case .fixtureMissing: return text("mediakit.error.fixtureMissing")
        }
    }

    /// Catalogue key + `%@` arguments; every `MediaKitError` case has a key (`MediaKitErrorCatalogTests`).
    private static func text(_ key: String, _ arguments: String...) -> String {
        String(format: String(localized: String.LocalizationValue(key), bundle: .module), arguments: arguments)
    }

    static func message(for error: any Error) -> String {
        if let mk = error as? MediaKitError { return message(for: mk) }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Unreachable in the aggregator's sense: the host, not the request, is the problem.
    static func isUnreachable(_ error: any Error) -> Bool {
        guard let mk = error as? MediaKitError else { return false }
        switch mk {
        case .unreachable, .breakerOpen: return true
        case let .serverFault(_, status, _): return [502, 503, 504].contains(status)
        case let .rejected(_, status, _): return [404, 408, 410].contains(status)
        default: return false
        }
    }
}

nonisolated public extension Error {
    /// The message to put in front of a user: `localizedDescription` alone drops a
    /// `LocalizedError`'s own text and the arr's reason a `MediaKitError` carries.
    var userFacingMessage: String { MediaKitErrorPresenter.message(for: self) }
}

/// The title a row wears when the arr sent none.
nonisolated private var unknownTitle: String { String(localized: "queue.unknown.button", bundle: .module) }
