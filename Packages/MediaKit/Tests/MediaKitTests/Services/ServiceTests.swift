import Foundation
import Testing
@testable import MediaKit

/// Every fixture-backed resource decodes; the recorded shapes are the contract.
@Suite struct ServiceDecodingTests {
    static let all: [InstanceID] = [InstanceKind.radarr, .sonarr, .lidarr, .qbittorrent, .sabnzbd, .plex, .tmdb].map { InstanceID($0) }

    @Test func servarrResourcesDecodeFromFixtures() async throws {
        let kit = try await TestKit(instances: Self.all, fixtures: true)
        for id in [TestKit.radarr, TestKit.sonarr, InstanceID(.lidarr)] {
            let s = kit.store
            let svc = try #require(await kitServarr(kit, id))
            #expect(try await s.read(svc.status()).value.version != nil)
            _ = try await s.read(svc.health())
            #expect(try await s.read(svc.diskSpace()).value.count > 0)
            #expect(try await s.read(svc.queue()).value.records.count > 0)
            #expect(try await s.read(svc.calendar(start: Date(), end: Date())).value.count > 0)
            #expect(try await s.read(svc.history()).value.records.count > 0)
            #expect(try await s.read(svc.qualityProfiles()).value.count > 0)
            #expect(try await s.read(svc.rootFolders()).value.count > 0)
            #expect(try await s.read(svc.customFormats()).value.count >= 0)
            _ = try await s.read(svc.downloadClients())
            _ = try await s.read(svc.commands())
        }
        let radarr = kit.servarr(TestKit.radarr), sonarr = kit.servarr(TestKit.sonarr), lidarr = kit.servarr(InstanceID(.lidarr))
        let movies = try await kit.store.read(radarr.movies()).value
        #expect(movies.count > 0 && movies.first?.tmdbId != nil)
        #expect(try await kit.store.read(radarr.movie(id: movies[0].id!)).value.title.isEmpty == false)
        #expect(try await kit.store.read(radarr.lookupMovies(term: "bunny")).value.count > 0)
        #expect(try await kit.store.read(radarr.credits(movieID: 1)).value.count > 0)
        #expect(try await kit.store.read(radarr.alternateTitles()).value.count >= 0)
        let series = try await kit.store.read(sonarr.series()).value
        #expect(series.count > 0 && series.first?.seasons?.isEmpty == false)
        #expect(try await kit.store.read(sonarr.seriesDetails(id: series[0].id!)).value.tvdbId != nil)
        #expect(try await kit.store.read(sonarr.episodes(seriesID: 1)).value.count > 0)
        #expect(try await kit.store.read(sonarr.lookupSeries(term: "x")).value.count > 0)
        let artists = try await kit.store.read(lidarr.artists()).value
        #expect(artists.count > 0 && artists.first?.foreignArtistId != nil)
        #expect(try await kit.store.read(lidarr.artist(id: 1)).value.artistName != nil)
        #expect(try await kit.store.read(lidarr.albums(artistID: 1)).value.count > 0)
        #expect(try await kit.store.read(lidarr.album(id: 1)).value.title.isEmpty == false)
        #expect(try await kit.store.read(lidarr.tracks(albumID: 1)).value.count > 0)
        #expect(try await kit.store.read(lidarr.lidarrSearch(term: "x")).value.count > 0)
        #expect(try await kit.store.read(lidarr.metadataProfiles()).value.count > 0)
        let files = await kit.store.batch(radarr.files, keys: [movies[0].id!])
        #expect(files.isEmpty == false)
        let episodeFiles = await kit.store.batch(sonarr.files, keys: [1])
        #expect(episodeFiles.isEmpty == false)
        let queueRow = try await kit.store.read(sonarr.queue()).value.records[0]
        #expect(queueRow.series != nil || queueRow.seriesId != nil)
        #expect(await kit.identity.known(.arr(TestKit.radarr, movies[0].id!), in: .tmdbMovie) == .tmdbMovie(movies[0].tmdbId!))
    }

    @Test func tmdbResourcesDecodeFromFixtures() async throws {
        let kit = try await TestKit(instances: Self.all, fixtures: true)
        let tmdb = TMDBService(capabilities: kit.capabilities)
        let s = kit.store
        _ = try await s.read(tmdb.configuration())
        #expect(try await s.read(tmdb.searchPerson(query: "x")).value.results.count > 0)
        #expect(try await s.read(tmdb.movieCredits(id: 1)).value.cast.count > 0)
        #expect(try await s.read(tmdb.tvCredits(id: 1)).value.cast.count > 0)
        #expect(try await s.read(tmdb.movie(id: 1)).value.countryCodes(preferOrigin: false).count > 0)
        #expect(try await s.read(tmdb.tv(id: 1)).value.createdBy != nil)
        #expect(try await s.read(tmdb.movieVideos(id: 1)).value.results.count >= 0)
        #expect(try await s.read(tmdb.movieRecommendations(id: 1)).value.results.count > 0)
        #expect(try await s.read(tmdb.tvRecommendations(id: 1)).value.results.count > 0)
        #expect(try await s.read(tmdb.person(id: 1)).value.name.isEmpty == false)
        #expect(try await s.read(tmdb.personMovieCredits(id: 1)).value.cast.count > 0)
        #expect(try await s.read(tmdb.personTVCredits(id: 1)).value.cast.count > 0)
        #expect(try await s.read(tmdb.discoverMovies()).value.results.count > 0)
        #expect(try await s.read(tmdb.discoverTV()).value.results.count > 0)
        _ = try await s.read(tmdb.tvExternalIDs(id: 1))
        _ = try await s.read(tmdb.find(tvdbID: 1))
        let request = await kit.fixtures!.requestLog().first { $0.0.name == "searchPerson" }
        #expect(request != nil)
    }

    @Test func mediaServerAndDownloadClientsDecodeFromFixtures() async throws {
        let kit = try await TestKit(instances: Self.all, fixtures: true)
        let plex = MediaServerService(instance: InstanceID(.plex), capabilities: kit.capabilities)
        try await step("identity") { _ = try await kit.store.read(plex.identity()) }
        let libraries = try await step("libraries") { try await kit.store.read(plex.libraries()).value }
        #expect(libraries.count > 0)
        let index = try await step("index") { try await kit.store.read(plex.libraryIndex(section: libraries[0].key)).value }
        #expect(index.count > 0 && index.contains { !$0.ids.isEmpty })
        let sessions = try await step("sessions") { try plex.decodeSessions(try await kit.pipeline.send(plex.sessionsPlan())) }
        #expect(sessions.count >= 0)
        let history = try await step("history") { try await kit.store.read(plex.watchHistory()).value }
        #expect(history.count > 0)
        // Episodes carry where they sit in their series: that, not the
        // title-level flag, is what marks an Upcoming row as already watched.
        let playedEpisode = history.first { $0.kind == .episode }
        #expect(playedEpisode?.season != nil)
        #expect(playedEpisode?.episode != nil)
        #expect(playedEpisode?.seriesItemID?.isEmpty == false)
        let qb = QBittorrentService(instance: InstanceID(.qbittorrent), capabilities: kit.capabilities)
        let tasks = try await step("qb tasks") { try await qb.fetchTasks(ids: [], pipeline: kit.pipeline) }
        #expect(tasks.count > 0)
        let version = try await step("qb version") { try await kit.store.read(qb.version()).value }
        #expect(!version.isEmpty)
        let sab = SABnzbdService(instance: InstanceID(.sabnzbd))
        try await step("sab tasks") { _ = try await sab.fetchTasks(ids: [], pipeline: kit.pipeline) }
        let slots = try await step("sab history") { try await kit.store.read(sab.history()).value }
        #expect(slots.count >= 0)
    }

    func step<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { Issue.record("step \(name): \(error)"); throw error }
    }

    func kitServarr(_ kit: TestKit, _ id: InstanceID) async -> ServarrService? { kit.servarr(id) }
}

extension TestKit {
    func servarr(_ id: InstanceID) -> ServarrService { ServarrService(instance: id, profile: ServarrProfile.profile(for: id.kind)!, capabilities: capabilities) }
}

@Suite struct WriteShapeTests {
    @Test func seasonToggleUsesV5WhenCapableAndDoublePutOtherwise() async throws {
        let kit = try await TestKit()
        let sonarr = kit.servarr(TestKit.sonarr)
        let series = #"{"id":5,"title":"Sintel","seasons":[{"seasonNumber":1,"monitored":false},{"seasonNumber":2,"monitored":true}],"tags":[3],"customField":"kept"}"#
        kit.transport.fallback = { r in ScriptedTransport.Answer(status: 200, body: Data(r.method == "GET" ? series.utf8 : "{}".utf8)) }
        _ = try await kit.store.run(sonarr.setSeasonMonitored(seriesID: 5, season: 1, true))
        let v3 = kit.transport.requests.map { "\($0.method) \($0.pathTemplate)" }
        #expect(v3 == ["GET /api/v3/series/{id}", "PUT /api/v3/series/{id}", "GET /api/v3/series/{id}", "PUT /api/v3/series/{id}"])
        let puts = kit.transport.requests.filter { $0.method == "PUT" }.compactMap { r -> JSONValue? in
            guard case let .bytes(d, _) = r.body else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: d)
        }
        #expect(puts[0]["seasons"]?.arrayValue?[0]["monitored"]?.boolValue == false && puts[1]["seasons"]?.arrayValue?[0]["monitored"]?.boolValue == true)
        #expect(puts[1]["customField"]?.stringValue == "kept" && puts[1]["tags"]?.arrayValue?.count == 1)

        await kit.probe.promote(.servarrSeasonEndpointV5, for: TestKit.sonarr)
        let before = kit.transport.count
        _ = try await kit.store.run(sonarr.setSeasonMonitored(seriesID: 5, season: 2, false))
        #expect(kit.transport.requests.dropFirst(before).map { "\($0.method) \($0.pathTemplate)" } == ["PUT /api/v5/series/{id}/season"])
    }

    @Test func v5RejectionDemotesAndFallsBackOnce() async throws {
        let kit = try await TestKit()
        await kit.probe.promote(.servarrSeasonEndpointV5, for: TestKit.sonarr)
        let series = #"{"id":5,"title":"Sintel","seasons":[{"seasonNumber":1,"monitored":false}]}"#
        kit.transport.fallback = { r in
            if r.pathTemplate.hasPrefix("/api/v5") { return ScriptedTransport.Answer(status: 404, body: Data()) }
            return ScriptedTransport.Answer(status: 200, body: Data(r.method == "GET" ? series.utf8 : "{}".utf8))
        }
        _ = try await kit.store.run(kit.servarr(TestKit.sonarr).setSeasonMonitored(seriesID: 5, season: 1, true))
        #expect(kit.transport.count == 5 && !kit.capabilities.has(.servarrSeasonEndpointV5, TestKit.sonarr))
    }

    @Test func monitorToggleEchoesUnknownFields() async throws {
        let kit = try await TestKit()
        kit.transport.fallback = { r in ScriptedTransport.Answer(status: 200, body: Data((r.method == "GET" ? #"{"id":9,"title":"Big Buck Bunny","monitored":false,"weird":{"nested":[1,2]},"path":"/m"}"# : "{}").utf8)) }
        _ = try await kit.store.run(kit.servarr(TestKit.radarr).setMonitored(entityID: 9, true))
        let put = kit.transport.requests.last!
        guard case let .bytes(d, _) = put.body, let json = try? JSONDecoder().decode(JSONValue.self, from: d) else { Issue.record("no body"); return }
        #expect(json["monitored"]?.boolValue == true && json["weird"]?["nested"]?.arrayValue?.count == 2 && json["path"]?.stringValue == "/m")
        #expect(put.method == "PUT" && put.pathTemplate == "/api/v3/movie/{id}" && put.url.path == "/api/v3/movie/9")
    }

    @Test func searchCommandTracksCompletionAndInvalidatesQueue() async throws {
        let kit = try await TestKit()
        kit.transport.answer("searchMovie", json: #"{"id":77,"status":"queued"}"#, status: 201)
        kit.transport.answer("commandStatus", json: #"{"id":77,"status":"started"}"#)
        kit.transport.answer("commandStatus", json: #"{"id":77,"status":"completed"}"#)
        let receipt = try await kit.store.run(kit.servarr(TestKit.radarr).search(.movies([1, 2])))
        #expect(receipt.trackingID == 77)
        try await Task.sleep(for: .milliseconds(100))
        #expect(kit.transport.count("commandStatus") == 2)
        guard case let .bytes(d, _) = kit.transport.requests[0].body else { Issue.record("no body"); return }
        #expect(String(decoding: d, as: UTF8.self) == #"{"movieIds":[1,2],"name":"MoviesSearch"}"#)
    }

    @Test func qbittorrentAddSendsBothPausedSpellingsAndVerbsFollowCapability() async throws {
        let kit = try await TestKit(instances: [TestKit.qbittorrent], credentials: [TestKit.qbittorrent: Credentials(baseURL: URL(string: "http://qb.fixture.invalid")!, material: .apiKey("k"), generation: "g")])
        let qb = QBittorrentService(instance: TestKit.qbittorrent, capabilities: kit.capabilities)
        _ = try await kit.store.run(qb.add(DownloadPayload(.magnet("magnet:?xt=urn:btih:abc")), category: "movies", paused: true))
        guard case let .multipart(fields, _) = kit.transport.requests[0].body else { Issue.record("not multipart"); return }
        #expect(fields["paused"] == "true" && fields["stopped"] == "true" && fields["category"] == "movies" && fields["urls"]?.hasPrefix("magnet:") == true)
        #expect(kit.transport.requests[0].headers["Referer"] == "http://qb.fixture.invalid" && kit.transport.requests[0].headers["Authorization"] == "Bearer k")
        _ = try await kit.store.run(qb.action(.pause, ids: ["ABC"], deleteFiles: false))
        #expect(kit.transport.requests[1].pathTemplate == "/api/v2/torrents/pause")
        await kit.probe.promote(.qbittorrentStopStartVerbs, for: TestKit.qbittorrent)
        _ = try await kit.store.run(qb.action(.pause, ids: ["ABC"], deleteFiles: false))
        #expect(kit.transport.requests[2].pathTemplate == "/api/v2/torrents/stop")
        if case let .form(f) = kit.transport.requests[2].body { #expect(f["hashes"] == "abc") }
    }

    @Test func transmissionHandshakeRetriesOnceWithTheSessionHeader() async throws {
        let id = InstanceID(.transmission)
        let kit = try await TestKit(instances: [id], credentials: [id: Credentials(baseURL: URL(string: "http://tr.fixture.invalid")!, material: .userPassword(user: "u", password: "p"), generation: "g")])
        kit.transport.fallback = { r in
            if r.headers["X-Transmission-Session-Id"] == "S1" { return ScriptedTransport.Answer(status: 200, body: Data(#"{"result":"success","arguments":{"torrents":[]}}"#.utf8)) }
            var a = ScriptedTransport.Answer(status: 409, body: Data()); a.headers["X-Transmission-Session-Id"] = "S1"; return a
        }
        let tr = TransmissionService(instance: id)
        _ = try await tr.fetchTasks(ids: [], pipeline: kit.pipeline)
        _ = try await tr.fetchTasks(ids: [], pipeline: kit.pipeline)
        #expect(kit.transport.count == 3)
        #expect(kit.transport.requests[0].headers["Authorization"]?.hasPrefix("Basic ") == true)
        #expect(kit.transport.requests[2].headers["X-Transmission-Session-Id"] == "S1")
    }

    @Test func qbittorrentLogsInOncePerGeneration() async throws {
        let kit = try await TestKit(instances: [TestKit.qbittorrent], credentials: [TestKit.qbittorrent: Credentials(baseURL: URL(string: "http://qb.fixture.invalid")!, material: .userPassword(user: "u", password: "p"), generation: "g")])
        let logged = Flag()
        kit.transport.fallback = { r in
            if r.pathTemplate.hasSuffix("/auth/login") { logged.value = true; return ScriptedTransport.Answer(status: 200, body: Data("Ok.".utf8)) }
            return logged.value ? ScriptedTransport.Answer(status: 200, body: Data("[]".utf8)) : ScriptedTransport.Answer(status: 403, body: Data())
        }
        let qb = QBittorrentService(instance: TestKit.qbittorrent, capabilities: kit.capabilities)
        _ = try await qb.fetchTasks(ids: [], pipeline: kit.pipeline)
        _ = try await qb.fetchTasks(ids: [], pipeline: kit.pipeline)
        #expect(kit.transport.operations == ["fetchProgress", "login", "fetchProgress", "fetchProgress"])
        if case let .form(f) = kit.transport.requests[1].body { #expect(f["username"] == "u" && f["password"] == "p") } else { Issue.record("login body") }
    }

    @Test func rtorrentMulticallRoundTrip() throws {
        let response = """
        <?xml version="1.0"?><methodResponse><params><param><value><array><data>
        <value><array><data><value><string>ABCDEF</string></value><value><string>Big Buck Bunny</string></value><value><i8>50</i8></value><value><i8>100</i8></value><value><i8>1024</i8></value><value><i8>1</i8></value><value><i8>1</i8></value><value><string>movies</string></value></data></array></value>
        </data></array></value></param></params></methodResponse>
        """
        let tasks = try RTorrentService(instance: InstanceID(.rtorrent)).decodeTasks(HTTPResponse(status: 200, body: Data(response.utf8)), ids: [])
        #expect(tasks.count == 1 && tasks[0].id == "abcdef" && tasks[0].progress == 0.5 && tasks[0].state == .downloading && tasks[0].category == "movies")
        let request = String(decoding: XMLRPC.request(method: "d.multicall2", params: [.string(""), .string("main"), .string("d.hash=")]), as: UTF8.self)
        #expect(request.contains("<methodName>d.multicall2</methodName>") && request.contains("<string>d.hash=</string>"))
        let fault = "<methodResponse><fault><value><struct><member><name>faultCode</name><value><int>-501</int></value></member><member><name>faultString</name><value><string>Could not find info-hash.</string></value></member></struct></value></fault></methodResponse>"
        #expect(throws: MediaKitError.self) { try RTorrentService(instance: InstanceID(.rtorrent)).decodeTasks(HTTPResponse(status: 200, body: Data(fault.utf8)), ids: []) }
    }
}

/// Criterion 26: every corpus (client, operation) pair is produced by a service plan, or is on the documented exclusion list.
@Suite struct GoldenParityTests {
    @Test func everyCorpusOperationHasAProducer() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/superpowers/baseline/2026-09-15-golden-requests.json")
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
        let corpus = Set(rows.map { "\($0.client).\($0.operation)" })
        let produced = Set(ProducedOperations.all().map(\.rawValue))
        let excluded: Set<String> = ["tmdb.similarMovies", "tmdb.similarTV", "qbittorrent.contains", "sabnzbd.contains", "tmdb.tvCreators", "sonarr.realtime.negotiate"]
        let missing = corpus.subtracting(produced).subtracting(excluded).sorted()
        #expect(missing.isEmpty, "not produced: \(missing)")
    }

    struct Row: Decodable { let client: String; let operation: String }
}

enum ProducedOperations {
    static func all() -> [OperationID] {
        let caps = CapabilityIndex()
        var ops: [OperationID] = []
        for kind in [InstanceKind.radarr, .sonarr, .lidarr, .whisparr] {
            let s = ServarrService(instance: InstanceID(kind), profile: ServarrProfile.profile(for: kind)!, capabilities: caps)
            ops += [s.status().plan, s.health().plan, s.diskSpace().plan, s.queuePlan(), s.calendar(start: Date(), end: Date()).plan, s.history().plan,
                    s.historyFor(entityID: 1).plan, s.movies().plan, s.series().plan, s.artists().plan, s.movie(id: 1).plan, s.seriesDetails(id: 1).plan,
                    s.artist(id: 1).plan, s.album(id: 1).plan, s.episodes(seriesID: 1).plan, s.albums(artistID: 1).plan, s.tracks(albumID: 1).plan,
                    s.credits(movieID: 1).plan, s.alternateTitles().plan, s.qualityProfiles().plan, s.metadataProfiles().plan, s.rootFolders().plan,
                    s.customFormats().plan, s.downloadClients().plan, s.commands().plan, s.lookupMovies(term: "").plan, s.lookupSeries(term: "").plan,
                    s.lookupArtists(term: "").plan, s.lidarrSearch(term: "").plan, s.releases(entityID: 1).plan].map(\.operation)
            switch s.files.strategy {
            case let .chunked(_, make, _): ops.append(make([1]).plan.operation)
            case let .perKey(make): ops.append(make(1).plan.operation)
            }
            ops += [s.deleteQueueItem(id: 1, removeFromClient: true, blocklist: false, now: Date()), s.grabQueueItem(id: 1), s.grabRelease(guid: "g", indexerID: 1),
                    s.search(.movies([1])), s.search(.series(1)), s.search(.season(seriesID: 1, season: 1)), s.search(.episodes([1])), s.search(.albums([1])),
                    s.command(named: "RefreshMovie"), s.setMonitored(entityID: 1, true), s.setAlbumMonitored(albumID: 1, true), s.setEpisodesMonitored(ids: [1], true),
                    s.setSeasonMonitored(seriesID: 1, season: 1, true), s.add(ArrAddPayload(qualityProfileId: 1, rootFolderPath: "/")),
                    s.addAlbum(foreignAlbumID: "x", term: "x", payload: ArrAddPayload(qualityProfileId: 1, rootFolderPath: "/")),
                    s.update(entityID: 1) { _ in }, s.delete(entityID: 1, deleteFiles: false, addImportExclusion: false)].map(\.name)
            ops += ["search.fetchLibraryOwnership", "search.fetchQualityProfiles"].map { OperationID(kind, $0) }   // same requests as library/qualityProfiles
        }
        let downloads: [any DownloadService] = [QBittorrentService(instance: InstanceID(.qbittorrent), capabilities: caps), TransmissionService(instance: InstanceID(.transmission)),
                                                DelugeService(instance: InstanceID(.deluge)), RTorrentService(instance: InstanceID(.rtorrent)),
                                                SABnzbdService(instance: InstanceID(.sabnzbd)), NZBGetService(instance: InstanceID(.nzbget))]
        for d in downloads {
            ops += [d.version().plan.operation, d.tasks(ids: []).operation, d.defaultAddPaused().plan.operation]
            ops += [DownloadAction.pause, .resume, .delete, .forceStart].map { d.action($0, ids: ["a"], deleteFiles: false).name }
            ops += [d.add(DownloadPayload(.magnet("m")), category: nil, paused: false).name, d.add(DownloadPayload(.file(Data(), filename: "f")), category: nil, paused: false).name]
        }
        ops.append(SABnzbdService(instance: InstanceID(.sabnzbd)).history().plan.operation)
        for kind in [InstanceKind.plex, .jellyfin, .emby] {
            let m = MediaServerService(instance: InstanceID(kind), capabilities: caps, userID: "u")
            ops += [m.identity().plan, m.libraries().plan, m.libraryIndex(section: "1").plan, m.sessionsPlan(), m.watchHistory().plan, m.seasonArtwork(item: "1").plan, m.users().plan].map(\.operation)
            ops += [m.scanLibrary(section: "1").name, m.emptyTrash(section: "1").name]
        }
        let t = TMDBService(capabilities: caps)
        ops += [t.configuration().plan, t.searchPerson(query: "").plan, t.movie(id: 1).plan, t.movieCredits(id: 1).plan, t.movieVideos(id: 1).plan, t.movieRecommendations(id: 1).plan,
                t.tv(id: 1).plan, t.tvCredits(id: 1).plan, t.tvVideos(id: 1).plan, t.tvRecommendations(id: 1).plan, t.tvExternalIDs(id: 1).plan, t.find(tvdbID: 1).plan,
                t.person(id: 1).plan, t.personMovieCredits(id: 1).plan, t.personTVCredits(id: 1).plan, t.discoverMovies().plan, t.discoverTV().plan].map(\.operation)
        return ops
    }
}

@Suite struct DownloadAddShapeTests {
    private func kit(_ kind: InstanceKind) async throws -> (TestKit, InstanceID) {
        let id = InstanceID(kind)
        let material: Credentials.Material = kind == .sabnzbd ? .apiKey("k") : .userPassword(user: "u", password: "p")
        let kit = try await TestKit(instances: [id], credentials: [id: Credentials(baseURL: URL(string: "http://dl.fixture.invalid:8080")!, material: material, generation: "g")])
        return (kit, id)
    }

    private func body(_ request: HTTPRequest) -> String {
        if case let .bytes(d, _) = request.body { return String(decoding: d, as: UTF8.self) }
        return ""
    }

    @Test func transmissionCategoryBecomesADownloadSubdirectory() async throws {
        let (kit, id) = try await kit(.transmission)
        kit.transport.answer("addMagnet", json: #"{"result":"success","arguments":{"download-dir":"/data/downloads"}}"#)
        kit.transport.answer("addMagnet", json: #"{"result":"success","arguments":{}}"#)
        _ = try await kit.store.run(TransmissionService(instance: id).add(DownloadPayload(.magnet("magnet:?xt=urn:btih:abc")), category: "tv", paused: true))
        let add = kit.transport.requests[1]
        #expect(add.rpcMethod == "torrent-add" && body(add).contains(#""download-dir":"/data/downloads/tv""#) && body(add).contains(#""paused":true"#))
    }

    @Test func sabnzbdUploadsMultipartUnderTheCategoryWithPausedPriority() async throws {
        let (kit, id) = try await kit(.sabnzbd)
        kit.transport.answer("addFile", json: #"{"status":true}"#)
        _ = try await kit.store.run(SABnzbdService(instance: id).add(DownloadPayload(.file(Data("nzb".utf8), filename: "x.nzb")), category: "tv", paused: true))
        let request = kit.transport.requests[0]
        let query = request.url.query ?? ""
        #expect(query.contains("mode=addfile") && query.contains("cat=tv") && query.contains("priority=-2") && query.contains("apikey="))
        if case let .multipart(_, file) = request.body { #expect(file?.name == "name" && file?.filename == "x.nzb") } else { Issue.record("not multipart") }
    }

    @Test func nzbgetAppendCarriesTheFileBase64WithCategoryAndPaused() async throws {
        let (kit, id) = try await kit(.nzbget)
        kit.transport.answer("addFile", json: #"{"result":42}"#)
        _ = try await kit.store.run(NZBGetService(instance: id).add(DownloadPayload(.file(Data("nzb".utf8), filename: "x.nzb")), category: "tv", paused: true))
        let text = body(kit.transport.requests[0])
        #expect(text.contains(#""method":"append""#) && text.contains(Data("nzb".utf8).base64EncodedString()) && text.contains(#""tv""#) && text.contains("true"))
        #expect(kit.transport.requests[0].headers["Authorization"]?.hasPrefix("Basic ") == true)
    }

    @Test func rtorrentLoadPicksTheNonStartingMethodWhenPaused() async throws {
        let (kit, id) = try await kit(.rtorrent)
        kit.transport.answer("addMagnet", json: "<methodResponse><params><param><value><i4>0</i4></value></param></params></methodResponse>")
        _ = try await kit.store.run(RTorrentService(instance: id).add(DownloadPayload(.magnet("magnet:?xt=urn:btih:abc")), category: "tv", paused: true))
        let text = body(kit.transport.requests[0])
        #expect(kit.transport.requests[0].rpcMethod == "load.normal" && text.contains("d.custom1.set=tv"))
    }
}
