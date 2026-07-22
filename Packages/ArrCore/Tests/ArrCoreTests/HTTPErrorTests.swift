import Testing
import Foundation
@testable import ArrCore

@Suite("HTTPError server-message surfacing")
struct HTTPErrorTests {
    @Test("Parses Servarr validation array")
    func validationArray() {
        let body = #"[{"propertyName":"Title","errorMessage":"This series has already been added","severity":"error"}]"#
        #expect(HTTPError.serverMessage(from: body) == "This series has already been added")
    }

    @Test("Joins multiple validation errors")
    func multipleErrors() {
        let body = #"[{"errorMessage":"Invalid quality profile"},{"errorMessage":"Root folder does not exist"}]"#
        #expect(HTTPError.serverMessage(from: body) == "Invalid quality profile; Root folder does not exist")
    }

    @Test("Parses single message object")
    func messageObject() {
        let body = #"{"message":"Series not found"}"#
        #expect(HTTPError.serverMessage(from: body) == "Series not found")
    }

    @Test("Parses ASP.NET ProblemDetails errors dictionary")
    func problemDetailsErrors() {
        let body = #"{"title":"One or more validation errors occurred.","status":400,"errors":{"RootFolderPath":["Path does not exist"]}}"#
        #expect(HTTPError.serverMessage(from: body) == "Path does not exist")
    }

    @Test("Falls back to ProblemDetails title when no errors dict")
    func problemDetailsTitle() {
        let body = #"{"title":"Series not found","status":400}"#
        #expect(HTTPError.serverMessage(from: body) == "Series not found")
    }

    @Test("Falls back to raw text for non-JSON body")
    func rawText() {
        #expect(HTTPError.serverMessage(from: "Bad Request") == "Bad Request")
    }

    @Test("Returns nil for empty or absent body")
    func emptyBody() {
        #expect(HTTPError.serverMessage(from: nil) == nil)
        #expect(HTTPError.serverMessage(from: "   ") == nil)
    }

    @Test("errorDescription includes the parsed detail")
    func descriptionIncludesDetail() {
        let err = HTTPError.status(400, body: #"[{"errorMessage":"This series has already been added"}]"#)
        #expect(err.errorDescription == "HTTP 400: This series has already been added")
    }

    /// Servarr answers a bad API key with 401 and an *empty* body, so the
    /// generic path renders a bare "HTTP 401" that names neither cause nor fix.
    /// Asserted by shape, not by exact wording — the hint is localized.
    @Test("Auth failures explain themselves even with no body", arguments: [401, 403])
    func authFailureCarriesAHint(_ code: Int) {
        let bare = HTTPError.status(code, body: nil).errorDescription
        #expect(bare?.hasPrefix("HTTP \(code): ") == true)
        #expect(bare != "HTTP \(code)")
    }

    @Test("An auth failure that does carry a body keeps the server's reason")
    func authFailureKeepsServerDetail() {
        // qBittorrent's login rejection, unlike Servarr's, has a body.
        let desc = HTTPError.status(403, body: "Fails.").errorDescription
        #expect(desc?.contains("(Fails.)") == true)
    }
}

@Suite("HTTPClient URL + form encoding")
struct HTTPClientEncodingTests {
    @Test("Form fields escape the separators that used to split them apart")
    func formEscapesSeparators() {
        // Under `.urlQueryAllowed` this password was spliced into extra fields
        // ("password=p", "ss=w+rd") and qBittorrent login failed with a 403 loop.
        #expect(HTTPClient.encodeForm(["username": "admin", "password": "p&ss=w+rd"])
                == "password=p%26ss%3Dw%2Brd&username=admin")
    }

    @Test("Form values keep spaces and non-ASCII percent-encoded, never literal")
    func formEscapesSpacesAndUnicode() {
        #expect(HTTPClient.encodeForm(["q": "a b"]) == "q=a%20b")
        #expect(HTTPClient.encodeForm(["q": "café"]) == "q=caf%C3%A9")
    }

    @Test("Query keeps '+' encoded so ASP.NET doesn't read it as a space")
    func queryEscapesPlus() throws {
        let url = try HTTPClient().url(base: "https://host", path: "/api/v3/search",
                                       query: [URLQueryItem(name: "term", value: "Disney+")])
        #expect(url.absoluteString == "https://host/api/v3/search?term=Disney%2B")
    }

    @Test("Escaping '+' leaves everything else URLComponents encoded intact")
    func queryPlusFixIsSurgical() throws {
        let url = try HTTPClient().url(base: "https://host", path: "/x",
                                       query: [URLQueryItem(name: "t", value: "a&b=c d é+f")])
        #expect(url.absoluteString == "https://host/x?t=a%26b%3Dc%20d%20%C3%A9%2Bf")
    }

    @Test("Trailing slashes on the base never double up in the joined path",
          arguments: ["https://host/sonarr", "https://host/sonarr/", "https://host/sonarr//"])
    func baseTrailingSlashes(_ base: String) throws {
        let url = try HTTPClient().url(base: base, path: "/api/v3/queue")
        #expect(url.absoluteString == "https://host/sonarr/api/v3/queue")
    }

    @Test("A bare host with no path still joins cleanly")
    func baseWithoutPath() throws {
        for base in ["https://host", "https://host/"] {
            let url = try HTTPClient().url(base: base, path: "/api/v3/queue")
            #expect(url.absoluteString == "https://host/api/v3/queue")
        }
    }
}

@Suite("SonarrMonitorMode API mapping")
struct SonarrMonitorModeTests {
    @Test("Season modes map to Sonarr's camelCase MonitorTypes")
    func seasonModes() {
        #expect(SonarrMonitorMode.first.apiValue == "firstSeason")
        #expect(SonarrMonitorMode.latest.apiValue == "latestSeason")
    }

    @Test("Other modes map 1:1 to their raw value")
    func passthroughModes() {
        for mode in [SonarrMonitorMode.all, .future, .missing, .existing, .none] {
            #expect(mode.apiValue == mode.rawValue)
        }
    }
}
