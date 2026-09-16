import Foundation

public enum ExternalIDParsing {
    /// `tmdb://603`, `tvdb://81189`, `imdb://tt0133093`, legacy `com.plexapp.agents.imdb://tt…?lang=en`; `plex://` and `local://` are skipped.
    public static func plexGuids(_ guids: [String], kind: MediaKind) -> Set<MediaID> {
        var out = Set<MediaID>()
        for guid in guids {
            guard let scheme = guid.split(separator: ":", maxSplits: 1).first.map(String.init) else { continue }
            var value = String(guid.dropFirst(scheme.count + 3))
            if let q = value.firstIndex(of: "?") { value = String(value[..<q]) }
            if let slash = value.firstIndex(of: "/") , scheme.contains("agents") { value = String(value[..<slash]) }
            let agent = scheme.lowercased()
            if agent == "tmdb" || agent.hasSuffix("themoviedb"), let id = Int(value) {
                out.insert(kind == .movie ? .tmdbMovie(id) : .tmdbSeries(id))
            } else if agent == "tvdb" || agent.hasSuffix("thetvdb"), let id = Int(value) {
                out.insert(.tvdb(id))
            } else if agent == "imdb" || agent.hasSuffix("agents.imdb"), value.hasPrefix("tt") {
                out.insert(.imdb(value))
            }
        }
        return out
    }

    public static func jellyfinProviderIDs(_ ids: [String: String], kind: MediaKind) -> Set<MediaID> {
        var out = Set<MediaID>()
        for (name, value) in ids {
            switch name.lowercased() {
            case "tmdb": if let id = Int(value) { out.insert(kind == .movie ? .tmdbMovie(id) : .tmdbSeries(id)) }
            case "tvdb": if let id = Int(value) { out.insert(.tvdb(id)) }
            case "imdb": if value.lowercased().hasPrefix("tt") { out.insert(.imdb(value)) }
            case "musicbrainzartist": out.insert(.musicBrainz(.musicBrainzArtist, value))
            case "musicbrainzalbum", "musicbrainzreleasegroup": out.insert(.musicBrainz(.musicBrainzAlbum, value))
            case "musicbrainztrack": out.insert(.musicBrainz(.musicBrainzTrack, value))
            default: break
            }
        }
        return out
    }

    public static func servarrIDs(tmdbId: Int?, imdbId: String?, tvdbId: Int?, foreignId: String?, kind: MediaKind) -> Set<MediaID> {
        var out = Set<MediaID>()
        if let tmdbId, tmdbId > 0 { out.insert(kind == .movie ? .tmdbMovie(tmdbId) : .tmdbSeries(tmdbId)) }
        if let imdbId, imdbId.lowercased().hasPrefix("tt") { out.insert(.imdb(imdbId)) }
        if let tvdbId, tvdbId > 0 { out.insert(.tvdb(tvdbId)) }
        if let foreignId, !foreignId.isEmpty {
            switch kind {
            case .artist: out.insert(.musicBrainz(.musicBrainzArtist, foreignId))
            case .album: out.insert(.musicBrainz(.musicBrainzAlbum, foreignId))
            case .track: out.insert(.musicBrainz(.musicBrainzTrack, foreignId))
            default: break
            }
        }
        return out
    }

    public static func tmdbExternalIDs(imdb: String?, tvdb: Int?) -> Set<MediaID> {
        var out = Set<MediaID>()
        if let imdb, imdb.lowercased().hasPrefix("tt") { out.insert(.imdb(imdb)) }
        if let tvdb, tvdb > 0 { out.insert(.tvdb(tvdb)) }
        return out
    }
}
