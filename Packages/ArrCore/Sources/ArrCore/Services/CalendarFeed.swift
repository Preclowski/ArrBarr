import Foundation

/// Apple Calendar subscribes to the arr's own iCal feed and refreshes it itself, so no sync code.
enum CalendarFeed {

    /// `webcal://host[:port][/base]/feed/<v>/calendar/<App>.ics?apikey=…`; the base path is kept
    /// for reverse-proxy subpaths. nil without an API key, which the feed requires.
    static func subscriptionURL(kind: ServiceKind, config: ServiceConfig) -> URL? {
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
        comps.scheme = "webcal"
        let base = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = base + feedPath
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "apikey", value: config.apiKey))
        comps.queryItems = items
        return comps.url
    }
}
