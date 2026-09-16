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
        #expect(req("GET", "/3/movie/603", kind: .tmdb) && !req("GET", "/3/authentication/token/new", kind: .tmdb))
        #expect(!req("GET", "/library/sections/1/refresh", kind: .plex))
    }
}
