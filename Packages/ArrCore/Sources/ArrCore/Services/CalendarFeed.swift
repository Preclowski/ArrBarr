import Foundation

/// Builds the `webcal://` subscription URL for an arr's built-in iCal
/// calendar feed (Sonarr/Radarr/Lidarr/Whisparr each serve one). Opening
/// the URL hands off to Apple Calendar's native "Subscribe to calendar"
/// flow on both iOS and macOS — the arr then serves the feed and Calendar
/// refreshes it on its own, so ArrBarr needs zero sync code.
public enum CalendarFeed {

    /// Only media-manager arrs expose a calendar feed (download clients don't).
    public static func isSupported(_ kind: ServiceKind) -> Bool {
        switch kind {
        case .sonarr, .radarr, .lidarr, .whisparr: return true
        default: return false
        }
    }

    /// `webcal://host[:port][/base]/feed/<v>/calendar/<App>.ics?apikey=…`
    /// Returns nil for non-arr kinds, an unconfigured service, or a missing
    /// API key (the feed requires it). The base path is preserved so it works
    /// behind a reverse proxy subpath.
    public static func subscriptionURL(kind: ServiceKind, config: ServiceConfig) -> URL? {
        guard config.isConfigured, !config.apiKey.isEmpty else { return nil }
        let feedPath: String
        switch kind {
        case .sonarr:   feedPath = "/feed/v3/calendar/Sonarr.ics"
        case .radarr:   feedPath = "/feed/v3/calendar/Radarr.ics"
        case .lidarr:   feedPath = "/feed/v1/calendar/Lidarr.ics"   // Lidarr API is v1
        case .whisparr: feedPath = "/feed/v3/calendar/Whisparr.ics"
        default: return nil
        }
        guard var comps = URLComponents(string: config.baseURL) else { return nil }
        // webcal:// is the scheme Apple Calendar treats as "subscribe".
        comps.scheme = "webcal"
        let base = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = base + feedPath
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "apikey", value: config.apiKey))
        comps.queryItems = items
        return comps.url
    }
}
