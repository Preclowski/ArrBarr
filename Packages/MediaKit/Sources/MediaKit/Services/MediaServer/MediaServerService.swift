import Foundation

/// Plex, Jellyfin and Emby behind one vocabulary; the auth placement and the wire shape are the two switches.
public struct MediaServerService: Sendable {
    public let instance: InstanceID
    private let capabilities: CapabilityIndex
    public let userID: String?

    public init(instance: InstanceID, capabilities: CapabilityIndex, userID: String? = nil) {
        self.instance = instance; self.capabilities = capabilities; self.userID = userID
    }

    public var isPlex: Bool { instance.kind == .plex }

    private var auth: RequestPlan.AuthPlacement {
        switch instance.kind {
        case .plex: .header("X-Plex-Token")
        case .jellyfin: .jellyfinMediaBrowser
        default: .header("X-Emby-Token")
        }
    }

    private func plan(_ op: String, method: String = "GET", path: String, values: [String: String] = [:], query: [(String, String)] = [], priority: RequestPriority = .interactive) -> RequestPlan {
        RequestPlan(instance: instance, operation: op, method: method, pathTemplate: path, pathValues: values, query: query.map { .init($0.0, $0.1) },
                    headers: isPlex ? ["Accept": "application/json"] : [:], auth: auth, priority: priority)
    }

    private func tag(_ c: CollectionName) -> InvalidationTag { .collection(c, instance) }
    private var user: String { userID ?? "" }

    // MARK: - Resources

    public func identity() -> Resource<MediaServerIdentity> {
        let p = plan("testConnection", path: isPlex ? "/identity" : "/System/Info")
        let plex = isPlex
        return Resource(plan: p, tags: [.capabilities(instance)], freshness: .reference) { data in
            if plex {
                let c = try WireCodec.decoder.decode(PlexContainer<PlexMetadata>.self, from: data).MediaContainer
                return MediaServerIdentity(version: c.version, name: c.friendlyName, identifier: c.machineIdentifier)
            }
            let info = try WireCodec.decoder.decode(JellyfinInfo.self, from: data)
            return MediaServerIdentity(version: info.Version, name: info.ServerName, identifier: info.Id)
        }
    }

    public func users() -> Resource<[MediaServerUser]> {
        Resource(plan: plan("users", path: "/Users"), tags: [.capabilities(instance)], freshness: .reference) { data in
            try WireCodec.decoder.decode([JellyfinUser].self, from: data).map { MediaServerUser(id: $0.Id, name: $0.Name) }
        }
    }

    public func libraries() -> Resource<[MediaServerLibrary]> {
        let p = plan("libraries", path: isPlex ? "/library/sections" : "/Library/VirtualFolders")
        let plex = isPlex
        return Resource(plan: p, tags: [tag(.library)], freshness: .reference) { data in
            if plex {
                return (try WireCodec.decoder.decode(PlexContainer<PlexDirectory>.self, from: data).MediaContainer.Directory ?? []).map {
                    MediaServerLibrary(key: $0.key, title: $0.title, kind: $0.type == "movie" ? .movie : $0.type == "show" ? .series : nil)
                }
            }
            return try WireCodec.decoder.decode([JellyfinFolder].self, from: data).compactMap { f in
                f.ItemId.map { MediaServerLibrary(key: $0, title: f.Name, kind: f.CollectionType == "movies" ? .movie : f.CollectionType == "tvshows" ? .series : nil) }
            }
        }
    }

    public func libraryIndex(section: String) -> Resource<[MediaServerIndexEntry]> {
        let p = isPlex
            ? plan("libraryIndex", path: "/library/sections/{key}/all", values: ["key": section], query: [("includeGuids", "1")])
            : plan("libraryIndex", path: "/Users/{userId}/Items", values: ["userId": user],
                   query: [("ParentId", section), ("Recursive", "true"), ("IncludeItemTypes", "Movie,Series"), ("Fields", "ProviderIds,UserData")])
        let instance = self.instance, plex = isPlex
        return Resource(plan: p, tags: [tag(.library)], freshness: .warm, decode: { data in
            plex ? try Self.plexIndex(data) : try Self.jellyfinIndex(data)
        }, harvest: { entries in
            entries.flatMap { e in e.ids.map { Crosswalk(from: .server(instance, e.itemID), to: $0, kind: e.kind, confidence: .asserted, source: .mediaServerGuid, fetchedAt: Date()) } }
        })
    }

    /// The live pump; never a store row.
    public func sessionsPlan() -> RequestPlan { plan("nowPlaying", path: isPlex ? "/status/sessions" : "/Sessions", priority: .background) }

    public func decodeSessions(_ response: HTTPResponse) throws -> [MediaServerSession] {
        let op = OperationID(instance.kind, "nowPlaying")
        do {
            if isPlex {
                return (try WireCodec.decoder.decode(PlexContainer<PlexMetadata>.self, from: response.body).MediaContainer.Metadata ?? []).compactMap { m in
                    guard let key = m.ratingKey else { return nil }
                    let progress = (m.viewOffset.map(Double.init) ?? 0) / max(Double(m.duration ?? 0), 1)
                    let transcoding = m.TranscodeSession?["videoDecision"]?.stringValue == "transcode" || m.TranscodeSession?["audioDecision"]?.stringValue == "transcode"
                    return MediaServerSession(itemID: key, title: m.title ?? "", user: m.User?["title"]?.stringValue, progress: m.duration == nil ? nil : progress,
                                              state: m.Player?["state"]?.stringValue ?? "playing", kind: Self.kind(m.type), parentTitle: m.grandparentTitle,
                                              device: m.Player?["title"]?.stringValue ?? m.Player?["product"]?.stringValue, isTranscoding: transcoding)
                }
            }
            return try WireCodec.decoder.decode([JellyfinSession].self, from: response.body).compactMap { s in
                guard let item = s.NowPlayingItem else { return nil }
                let progress = Double(s.PlayState?.PositionTicks ?? 0) / max(Double(item.RunTimeTicks ?? 0), 1)
                let transcoding = s.TranscodingInfo.map { $0.IsVideoDirect != true || $0.IsAudioDirect != true } ?? false
                return MediaServerSession(itemID: item.Id, title: item.Name ?? "", user: s.UserName, progress: item.RunTimeTicks == nil ? nil : progress,
                                          state: s.PlayState?.IsPaused == true ? "paused" : "playing", kind: Self.kind(item.itemType), parentTitle: item.SeriesName,
                                          device: s.DeviceName ?? s.Client, isTranscoding: transcoding)
            }
        } catch { throw MediaKitError.decoding(op, detail: WireCodec.describe(error)) }
    }

    public func watchHistory(limit: Int = 200) -> Resource<[MediaServerHistoryRow]> {
        let p = isPlex
            ? plan("recentlyWatched", path: "/status/sessions/history/all", query: [("sort", "viewedAt:desc"), ("X-Plex-Container-Start", "0"), ("X-Plex-Container-Size", String(limit))])
            : plan("recentlyWatched", path: "/Users/{userId}/Items", values: ["userId": user],
                   query: [("IsPlayed", "true"), ("Recursive", "true"), ("IncludeItemTypes", "Movie,Episode"), ("SortBy", "DatePlayed"), ("SortOrder", "Descending"), ("Limit", String(limit)), ("Fields", "ProviderIds,UserData")])
        let plex = isPlex, instance = self.instance
        return Resource(plan: p, tags: [tag(.history)], freshness: .warm, decode: { data in
            if plex {
                return (try WireCodec.decoder.decode(PlexContainer<PlexMetadata>.self, from: data).MediaContainer.Metadata ?? []).compactMap { m in
                    guard let key = m.ratingKey, let kind = Self.kind(m.type) ?? (m.type == "episode" ? .episode : nil) else { return nil }
                    return MediaServerHistoryRow(itemID: key, ids: ExternalIDParsing.plexGuids((m.Guid ?? []).map(\.id), kind: kind), kind: kind,
                                                 title: m.grandparentTitle ?? m.title ?? "", viewedAt: Date(timeIntervalSince1970: TimeInterval(m.viewedAt ?? 0)))
                }
            }
            return try WireCodec.decoder.decode(JellyfinItems.self, from: data).Items.compactMap { i in
                let kind: MediaKind = i.itemType == "Episode" ? .episode : Self.kind(i.itemType) ?? .movie
                return MediaServerHistoryRow(itemID: i.Id, ids: ExternalIDParsing.jellyfinProviderIDs(i.ProviderIds ?? [:], kind: kind == .episode ? .series : kind), kind: kind,
                                             title: i.SeriesName ?? i.Name ?? "", viewedAt: i.UserData?.LastPlayedDate.flatMap { try? Date($0, strategy: WireCodec.iso8601Fractional) } ?? Date(timeIntervalSince1970: 0))
            }
        }, harvest: { rows in
            rows.filter { $0.kind != .episode }.flatMap { r in r.ids.map { Crosswalk(from: .server(instance, r.itemID), to: $0, kind: r.kind, confidence: .asserted, source: .mediaServerGuid, fetchedAt: Date()) } }
        })
    }

    public func seasonArtwork(item: String) -> Resource<[String: String]> {
        let p = isPlex ? plan("seasonPosters", path: "/library/metadata/{id}/children", values: ["id": item])
                       : plan("seasonPosters", path: "/Shows/{id}/Seasons", values: ["id": item], query: [("userId", user)])
        let plex = isPlex
        return Resource(plan: p, tags: [.entity(instance, .series, Int(item) ?? 0)], freshness: .reference) { data in
            // Keyed by season number; the value is the Plex thumb path or the Jellyfin "<itemID>|<tag>" pair.
            if plex {
                var out: [String: String] = [:]
                let container = try WireCodec.decoder.decode(PlexContainer<PlexMetadata>.self, from: data).MediaContainer
                for m in (container.Metadata ?? []) + (container.Directory ?? []) {
                    if let index = m.index, let thumb = m.thumb, out[String(index)] == nil { out[String(index)] = thumb }
                }
                return out
            }
            var out: [String: String] = [:]
            for i in try WireCodec.decoder.decode(JellyfinItems.self, from: data).Items {
                if let number = i.IndexNumber, let tag = i.ImageTags?["Primary"] { out[String(number)] = "\(i.Id)|\(tag)" }
            }
            return out
        }
    }

    // MARK: - Commands

    public func scanLibrary(section: String) -> Command {
        let p = isPlex ? plan("scanLibrary", path: "/library/sections/{key}/refresh", values: ["key": section]) : plan("scanLibrary", method: "POST", path: "/Library/Refresh")
        return Command(name: p.operation, instance: instance, invalidates: [tag(.library)]) { ctx in _ = try await ctx.send(p); return CommandReceipt(acceptedAt: ctx.clock.now) }
    }

    public func emptyTrash(section: String) -> Command {
        let instance = self.instance
        guard isPlex else { return Command(name: OperationID(instance.kind, "emptyTrash"), instance: instance, invalidates: []) { _ in throw MediaKitError.unsupported(instance, Capability(rawValue: "emptyTrash")) } }
        let p = plan("emptyTrash", method: "PUT", path: "/library/sections/{key}/emptyTrash", values: ["key": section])
        return Command(name: p.operation, instance: instance, invalidates: [tag(.library)]) { ctx in _ = try await ctx.send(p); return CommandReceipt(acceptedAt: ctx.clock.now) }
    }

    // MARK: - Artwork

    /// Token-free by construction; the credential is a `HeaderRef` resolved at download time.
    public func artwork(for entry: MediaServerIndexEntry, baseURL: URL) -> ArtworkReference? {
        guard let path = entry.artworkPath else { return nil }
        if isPlex {
            return ArtworkReference(url: baseURL.appendingPathComponent(path), headers: ["X-Plex-Token": .credential(instance)], sizing: .plexTranscode(photoPath: path), kind: .poster)
        }
        let header = instance.kind == .jellyfin ? "Authorization" : "X-Emby-Token"
        return ArtworkReference(url: baseURL.appendingPathComponent("/Items/\(entry.itemID)/Images/Primary"), headers: [header: .credential(instance)],
                                sizing: .jellyfinFill(itemID: entry.itemID, tag: path), kind: .poster)
    }

    // MARK: - Decoders

    static func kind(_ type: String?) -> MediaKind? {
        switch type?.lowercased() { case "movie": .movie; case "show", "series": .series; default: nil }
    }

    static func plexIndex(_ data: Data) throws -> [MediaServerIndexEntry] {
        (try WireCodec.decoder.decode(PlexContainer<PlexMetadata>.self, from: data).MediaContainer.Metadata ?? []).compactMap { m in
            guard let key = m.ratingKey, let kind = kind(m.type) else { return nil }
            let watched = kind == .series ? (m.leafCount ?? 0) > 0 && (m.viewedLeafCount ?? 0) >= (m.leafCount ?? 0) : (m.viewCount ?? 0) > 0
            return MediaServerIndexEntry(itemID: key, kind: kind, ids: ExternalIDParsing.plexGuids((m.Guid ?? []).map(\.id), kind: kind), title: m.title ?? "",
                                         year: m.year, artworkPath: m.thumb, viewCount: m.viewCount ?? 0,
                                         lastViewedAt: m.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }, watched: watched)
        }
    }

    static func jellyfinIndex(_ data: Data) throws -> [MediaServerIndexEntry] {
        try WireCodec.decoder.decode(JellyfinItems.self, from: data).Items.compactMap { i in
            guard let kind = kind(i.itemType) else { return nil }
            return MediaServerIndexEntry(itemID: i.Id, kind: kind, ids: ExternalIDParsing.jellyfinProviderIDs(i.ProviderIds ?? [:], kind: kind), title: i.Name ?? "",
                                         year: i.ProductionYear, artworkPath: i.ImageTags?["Primary"], viewCount: i.UserData?.PlayCount ?? 0,
                                         lastViewedAt: i.UserData?.LastPlayedDate.flatMap { try? Date($0, strategy: WireCodec.iso8601Fractional) },
                                         watched: i.UserData?.Played ?? ((i.UserData?.PlayCount ?? 0) > 0))
        }
    }
}
