import Foundation

/// The add form's options for one arr: what Settings stores and what the open form holds.
nonisolated struct ArrAddDefaults: Codable, Hashable, Sendable {
    var qualityProfileId: Int?
    var metadataProfileId: Int?
    var rootFolder: String?
    /// Radarr and Whisparr.
    var movieMonitor: RadarrMonitorMode = .movieOnly
    var seriesMonitor: SonarrMonitorMode = .all
    var artistMonitor: LidarrMonitorMode = .all
    var seriesType: SonarrSeriesType = .standard
    /// `ServiceConfig.identityFingerprint` of the server the ids above were picked on.
    var server: String?

    /// A profile deleted on the arr must never reach an add.
    static func pick<T: Equatable>(_ saved: T?, among options: [T]) -> T? {
        if let saved, options.contains(saved) { return saved }
        return options.first
    }

    /// The same number can name another profile on another server, so its ids are dropped; the modes still apply.
    func forServer(_ fingerprint: String) -> ArrAddDefaults {
        guard server != fingerprint else { return self }
        var copy = self
        copy.qualityProfileId = nil
        copy.metadataProfileId = nil
        copy.rootFolder = nil
        copy.server = fingerprint
        return copy
    }
}

nonisolated extension ArrAddDefaults {
    /// Field by field: iCloud can bring a value from another build, and one unknown mode must not lose the rest.
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            try? container.decodeIfPresent(T.self, forKey: key)
        }
        qualityProfileId = value(.qualityProfileId)
        metadataProfileId = value(.metadataProfileId)
        rootFolder = value(.rootFolder)
        movieMonitor = value(.movieMonitor) ?? movieMonitor
        seriesMonitor = value(.seriesMonitor) ?? seriesMonitor
        artistMonitor = value(.artistMonitor) ?? artistMonitor
        seriesType = value(.seriesType) ?? seriesType
        server = value(.server)
    }
}
