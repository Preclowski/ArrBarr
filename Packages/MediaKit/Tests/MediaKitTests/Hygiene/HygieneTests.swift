import Foundation
import Testing
@testable import MediaKit

@Suite struct HygieneTests {
    @Test func redactionScrubsEveryKnownSecretCarrier() throws {
        let r = Redaction.standard
        var request = HTTPRequest(method: "POST", url: URL(string: "http://h/api?apikey=K&mode=queue&access_token=T")!, operation: "sabnzbd.x")
        request.headers["X-Api-Key"] = "K"; request.headers["Cookie"] = "SID=1"
        request.body = .form(["username": "u", "password": "p"])
        let s = r.scrub(request)
        #expect(s.headers["X-Api-Key"] == "<redacted>" && s.headers["Cookie"] == "<redacted>")
        #expect(!s.url.absoluteString.contains("K") && !s.url.absoluteString.contains("=T") && s.url.absoluteString.contains("mode=queue"))
        if case let .form(f) = s.body { #expect(f["password"] == "<redacted>" && f["username"] == "<redacted>") } else { Issue.record("body") }
        let rpc = try RequestBuilder.jsonRPC(method: "auth.login", params: .array([.string("hunter2")]))
        if case let .bytes(d, ct) = rpc {
            #expect(!String(decoding: r.scrub(d, contentType: ct, rpcMethod: "auth.login"), as: UTF8.self).contains("hunter2"))
        }
        #expect(r.loggableURL(URL(string: "https://h:8443/a/b?apikey=K")!) == "https://h:8443/a/b")
    }

    @Test func credentialsNeverPrint() {
        let c = Credentials(baseURL: URL(string: "http://h")!, material: .apiKey("SECRET"), generation: "g")
        #expect(!"\(c)".contains("SECRET") && !String(reflecting: c).contains("SECRET") && !"\(c)".contains("h"))
        #expect(Fingerprint(baseURL: URL(string: "http://H/Base/?x=1")!, generation: "g").rawValue == "http://h/Base|g")
    }

    @Test func telemetryReportCarriesNoURL() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: "[]")
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        _ = try await kit.store.read(r)
        _ = try await kit.store.read(r)
        let report = kit.telemetry.report()
        #expect(report.contains("radarr.fetchQueue: 1") && report.contains("hits 1") && !report.contains("http"))
    }

    @Test func telemetryReportCountsEveryKindOfEventPerHost() async throws {
        let kit = try await TestKit()
        // Applying the registry already invalidated each instance once.
        let before = (kit.telemetry.cacheCounters(for: TestKit.radarr).invalidations, kit.telemetry.cacheCounters(for: TestKit.sonarr).invalidations)
        kit.transport.delay = .milliseconds(50)
        kit.transport.answer("fetchQueue", json: "[]")
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        async let first = kit.store.read(r)
        async let second = kit.store.read(r)
        _ = try await (first, second)
        _ = try await kit.store.read(r)
        await kit.store.invalidate([.collection(.queue, TestKit.radarr), .entity(TestKit.radarr, .movie, 1)], reason: .event)
        await kit.store.invalidate([.collection(.queue, TestKit.sonarr)], reason: .command)
        kit.transport.delay = .zero
        kit.transport.fallback = { _ in throw URLError(.cannotConnectToHost) }
        // One strike per read, however many attempts it made: three failed reads open the breaker, the next two are skipped.
        for _ in 0..<5 { _ = try? await kit.pipeline.send(kit.plan("fetchHealth", path: "/api/v3/health")) }
        let report = kit.telemetry.report()
        #expect(report.contains("radarr.fixture.invalid:8080: requests 10 skipped 2 failures 9 breaker 1 "))
        #expect(report.contains("radarr#0: hits 1 misses 2 stale 0 coalesced 1 invalidated \(before.0 + 1)"))
        #expect(report.contains("sonarr#0: hits 0 misses 0 stale 0 coalesced 0 invalidated \(before.1 + 1)"))
    }

    @Test func fixtureTransportAnswersFromTheBundleAndRefusesUnknownReads() async throws {
        let transport = FixtureTransport(clock: TestClock())
        let ok = try await transport.send(HTTPRequest(method: "GET", url: URL(string: "http://demo/api/v3/queue")!, operation: "radarr.fetchQueue", pathTemplate: "/api/v3/queue"))
        #expect(ok.status == 200 && !ok.body.isEmpty)
        await #expect(throws: MediaKitError.fixtureMissing("radarr.nope")) {
            try await transport.send(HTTPRequest(method: "GET", url: URL(string: "http://demo/api/v3/nope")!, operation: "radarr.nope", pathTemplate: "/api/v3/nope"))
        }
        let echo = try await transport.send(HTTPRequest(method: "PUT", url: URL(string: "http://demo/api/v3/movie/1")!, body: .bytes(Data(#"{"id":1}"#.utf8), contentType: "application/json"), operation: "radarr.update", pathTemplate: "/api/v3/movie/{id}"))
        #expect(echo.status == 200 && String(decoding: echo.body, as: UTF8.self) == #"{"id":1}"#)
        let command = try await transport.send(HTTPRequest(method: "POST", url: URL(string: "http://demo/api/v3/command")!, body: .bytes(Data("{}".utf8), contentType: "application/json"), operation: "radarr.search", pathTemplate: "/api/v3/command"))
        #expect(command.status == 201 && String(decoding: command.body, as: UTF8.self).contains("queued"))
    }

    @Test func demoDetailsAnswerForTheRequestedIDAndCalendarsFollowToday() async throws {
        let anchor = try #require(ISO8601DateFormatter().date(from: "2026-09-15T00:00:00Z"))
        let transport = FixtureTransport(clock: TestClock(start: anchor.addingTimeInterval(10 * 86_400)))
        func get(_ path: String, _ template: String, _ op: String) async throws -> JSONValue {
            let r = try await transport.send(HTTPRequest(method: "GET", url: URL(string: "http://demo\(path)")!, operation: OperationID(stringLiteral: op), pathTemplate: template))
            return try JSONDecoder().decode(JSONValue.self, from: r.body)
        }
        let movies = try await get("/api/v3/movie", "/api/v3/movie", "radarr.fetchAllMovies").arrayValue ?? []
        let sintel = try #require(movies.first { $0["title"]?.stringValue == "Sintel" }?["id"]?.intValue)
        #expect(try await get("/api/v3/movie/\(sintel)", "/api/v3/movie/{id}", "radarr.fetchMovieDetails")["title"]?.stringValue == "Sintel")
        let calendar = try await get("/api/v3/calendar", "/api/v3/calendar", "radarr.fetchCalendar").arrayValue ?? []
        let sherlock = try #require(calendar.first { $0["title"]?.stringValue == "Sherlock Jr." })
        #expect(sherlock["digitalRelease"]?.stringValue == "2026-09-25T00:00:00Z")
        // Its detail is the upcoming row, dated like the calendar, not the library's downloaded copy.
        let detail = try await get("/api/v3/movie/\(sherlock["id"]?.intValue ?? 0)", "/api/v3/movie/{id}", "radarr.fetchMovieDetails")
        #expect(detail["digitalRelease"]?.stringValue == "2026-09-25T00:00:00Z")
        #expect(detail["hasFile"]?.boolValue == false)
    }

    @Test func demoDatesCountTheViewersLocalDay() throws {
        let anchor = try #require(ISO8601DateFormatter().date(from: "2026-09-15T00:00:00Z"))
        let lateUTC = try #require(ISO8601DateFormatter().date(from: "2026-09-29T22:30:00Z"))
        var sydney = Calendar(identifier: .gregorian)
        sydney.timeZone = try #require(TimeZone(identifier: "Australia/Sydney"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(FixtureTransport.days(from: anchor, to: lateUTC, calendar: utc) == 14)
        #expect(FixtureTransport.days(from: anchor, to: lateUTC, calendar: sydney) == 15)
    }

    @Test func aDemoPauseSticksOnTheArrRowTrackingTheDownload() async throws {
        let transport = FixtureTransport(clock: TestClock())
        func queue() async throws -> [JSONValue] {
            let r = try await transport.send(HTTPRequest(method: "GET", url: URL(string: "http://demo/api/v3/queue")!, operation: "radarr.fetchQueue", pathTemplate: "/api/v3/queue"))
            return try JSONDecoder().decode(JSONValue.self, from: r.body)["records"]?.arrayValue ?? []
        }
        let row = try #require(try await queue().first { $0["downloadId"]?.stringValue?.isEmpty == false })
        let hash = try #require(row["downloadId"]?.stringValue)
        _ = try await transport.send(HTTPRequest(method: "POST", url: URL(string: "http://demo/api/v2/torrents/pause")!, body: .form(["hashes": hash.lowercased()]),
                                                 operation: "qbittorrent.pause", pathTemplate: "/api/v2/torrents/pause"))
        #expect(try await queue().first { $0["downloadId"] == row["downloadId"] }?["status"]?.stringValue == "paused")
    }

    @Test func allowListRefusesWritesAndReleases() {
        let list = AllowListProbe.section5
        func req(_ m: String, _ path: String, rpc: String? = nil, kind: InstanceKind) -> Bool {
            list.permits(HTTPRequest(method: m, url: URL(string: "http://h\(path)")!, operation: OperationID(kind, "x"), pathTemplate: path, rpcMethod: rpc), kind: kind)
        }
        #expect(req("GET", "/api/v3/queue", kind: .radarr))
        #expect(!req("GET", "/api/v3/release?movieId=1", kind: .radarr))
        #expect(!req("POST", "/api/v3/command", kind: .radarr))
        #expect(req("POST", "/signalr/messages/negotiate?negotiateVersion=1", kind: .sonarr))
        #expect(req("GET", "/api/v1/track?albumId=1", kind: .lidarr))
        #expect(req("POST", "/api/v2/auth/login", kind: .qbittorrent) && !req("POST", "/api/v2/torrents/stop", kind: .qbittorrent))
        #expect(req("POST", "/transmission/rpc", rpc: "torrent-get", kind: .transmission) && !req("POST", "/transmission/rpc", rpc: "torrent-stop", kind: .transmission))
        #expect(req("GET", "/api?mode=queue&output=json", kind: .sabnzbd) && !req("GET", "/api?mode=pause", kind: .sabnzbd))
        for action in ["pause", "resume", "purge", "priority", "delete"] {
            #expect(!req("GET", "/api?mode=queue&name=\(action)&value=SABnzbd_nzo_1", kind: .sabnzbd))
        }
        #expect(req("GET", "/3/movie/603", kind: .tmdb) && !req("GET", "/3/authentication/token/new", kind: .tmdb))
        #expect(!req("GET", "/library/sections/1/refresh", kind: .plex))
    }
}
