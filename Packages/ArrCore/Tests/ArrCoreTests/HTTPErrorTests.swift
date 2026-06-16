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
