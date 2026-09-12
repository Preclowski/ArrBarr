import SwiftUI

/// A third-party service whose own mark we draw rather than spelling its name
/// in type. The marks live in `ServiceIcons.xcassets` and are theirs, not ours:
/// none of them is redrawn or recoloured, and a service with no mark shipped
/// gets a named glyph instead of an invented logo.
///
/// Typed rather than string-keyed because the asset names are not guessable —
/// `rating-tmdb` is the wordmark on a chip, `brand-tmdb` is the square tile,
/// and picking the wrong one is a silent visual bug (SwiftUI draws nothing for
/// a name that misses). Both apps ask for a *service*; only this file knows
/// which asset that is.
public enum BrandService: String, Hashable, Sendable, CaseIterable {
    case imdb
    case tmdb
    case rottenTomatoes
    case tvdb
    case metacritic
    case plex
    case jellyfin
    case emby
    case radarr
    case sonarr
    case lidarr
    case whisparr
    case youtube
    case openai

    /// Lenient lookup from a name that arrived as data rather than as code —
    /// a `MediaKit.RatingService` case, a media server's own name, an
    /// availability source. Case-insensitive, and it knows the short forms
    /// these strings actually come in ("rt" for Rotten Tomatoes). Returns nil
    /// for anything unrecognised so the caller can draw its own placeholder
    /// rather than a wrong mark.
    public init?(name: String) {
        switch name.lowercased().replacingOccurrences(of: " ", with: "") {
        case "imdb": self = .imdb
        case "tmdb", "themoviedb": self = .tmdb
        case "rt", "rottentomatoes": self = .rottenTomatoes
        case "tvdb", "thetvdb": self = .tvdb
        case "metacritic": self = .metacritic
        case "plex": self = .plex
        case "jellyfin": self = .jellyfin
        case "emby": self = .emby
        case "radarr": self = .radarr
        case "sonarr": self = .sonarr
        case "lidarr": self = .lidarr
        case "whisparr": self = .whisparr
        case "youtube": self = .youtube
        case "openai": self = .openai
        default: return nil
        }
    }

    /// Spelled-out name, for tooltips and accessibility. Not localized: these
    /// are brand names, and a brand name is the same word everywhere.
    public var displayName: String {
        switch self {
        case .imdb: "IMDb"
        case .tmdb: "TMDB"
        case .rottenTomatoes: "Rotten Tomatoes"
        case .tvdb: "TheTVDB"
        case .metacritic: "Metacritic"
        case .plex: "Plex"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        case .radarr: "Radarr"
        case .sonarr: "Sonarr"
        case .lidarr: "Lidarr"
        case .whisparr: "Whisparr"
        case .youtube: "YouTube"
        case .openai: "OpenAI"
        }
    }

    /// The full-colour cut — IMDb yellow, RT red — which is what a chip on a
    /// neutral background wants.
    var assetName: String? {
        switch self {
        case .imdb: "rating-imdb"
        case .tmdb: "rating-tmdb"
        case .rottenTomatoes: "rating-rt"
        case .tvdb: "rating-tvdb"
        case .metacritic: nil
        case .plex: "plex"
        case .jellyfin: "jellyfin"
        case .emby: "emby"
        case .radarr: "radarr"
        case .sonarr: "sonarr"
        case .lidarr: "lidarr"
        case .whisparr: "whisparr"
        case .youtube: "brand-youtube"
        case .openai: "brand-openai"
        }
    }

    /// The single-ink cut, for marks drawn over artwork: a row of full-colour
    /// badges there reads as decoration, one ink reads as type. Falls back to
    /// the colour cut for services that ship only one.
    var monoAssetName: String? {
        switch self {
        case .imdb: "rating-imdb-mono"
        case .tmdb: "rating-tmdb-mono"
        case .tvdb: "rating-tvdb-mono"
        default: assetName
        }
    }

    /// What to draw when no mark ships. A glyph plus the service's name beats
    /// an approximation of somebody's logo.
    public var fallbackSymbol: String {
        switch self {
        case .metacritic: "m.square.fill"
        default: "star.fill"
        }
    }
}

/// One service's mark, at a given height.
///
/// The shared primitive between ArrBarr's popover and TonightBarr's window:
/// the two disagree about layout, type and chrome, and agree completely about
/// what IMDb's mark looks like. Anything that draws a service badge should
/// come through here rather than reaching for an asset name.
public struct BrandMark: View {
    private let service: BrandService?
    private let name: String
    private let height: CGFloat
    private let mono: Bool
    private let fallbackSymbol: String?
    private let fallbackTint: Color

    public init(_ service: BrandService, height: CGFloat = 12, mono: Bool = false,
                fallbackSymbol: String? = nil, fallbackTint: Color = .secondary) {
        self.service = service
        self.name = service.displayName
        self.height = height
        self.mono = mono
        self.fallbackSymbol = fallbackSymbol
        self.fallbackTint = fallbackTint
    }

    /// For a service that arrived as a string. An unrecognised name still
    /// renders — as `fallbackSymbol` labelled with the name it was given —
    /// because a source the build has never heard of is a normal thing for a
    /// media server to report, not a reason to draw nothing.
    public init(name: String, height: CGFloat = 12, mono: Bool = false,
                fallbackSymbol: String? = nil, fallbackTint: Color = .secondary) {
        let service = BrandService(name: name)
        self.service = service
        self.name = service?.displayName ?? name
        self.height = height
        self.mono = mono
        self.fallbackSymbol = fallbackSymbol
        self.fallbackTint = fallbackTint
    }

    public var body: some View {
        if let asset = service.flatMap({ mono ? $0.monoAssetName : $0.assetName }) {
            Image(asset, bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .help(Text(verbatim: name))
        } else if let symbol = fallbackSymbol ?? service?.fallbackSymbol {
            Image(systemName: symbol)
                .font(.system(size: height, weight: .semibold))
                .foregroundStyle(fallbackTint)
                .help(Text(verbatim: name))
        }
    }
}
