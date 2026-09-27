import Foundation
import Testing
@testable import MediaKit

@Suite struct ServerMessageTests {
    private func message(_ body: String) -> String? { RequestBuilder.serverMessage(from: Data(body.utf8)) }

    @Test func servarrValidationArrayJoinsEveryReason() {
        #expect(message(#"[{"errorMessage":"This series has already been added"}]"#) == "This series has already been added")
        #expect(message(#"[{"errorMessage":"Invalid quality profile"},{"errorMessage":"Root folder does not exist"}]"#)
                == "Invalid quality profile; Root folder does not exist")
    }

    @Test func singleObjectForms() {
        #expect(message(#"{"message":"Series not found"}"#) == "Series not found")
        #expect(message(#"{"title":"Series not found"}"#) == "Series not found")
    }

    @Test func problemDetailsErrorsWinOverTheTitle() {
        #expect(message(#"{"title":"One or more validation errors occurred.","errors":{"path":["Path does not exist"]}}"#) == "Path does not exist")
    }

    @Test func plainTextPassesThroughAndEmptyIsNil() {
        #expect(message("Bad Request") == "Bad Request")
        #expect(message("   ") == nil)
        #expect(RequestBuilder.serverMessage(from: Data()) == nil)
    }
}

@Suite struct RecordSettingsTests {
    private func current(root: String, path: String) throws -> ArrRecordSettings {
        try JSONDecoder().decode(ArrRecordSettings.self, from: Data(#"{"rootFolderPath":"\#(root)","path":"\#(path)","qualityProfileId":1}"#.utf8))
    }

    @Test func aNewRootMovesTheFolderAlong() throws {
        let edit = ArrRecordSettings(rootFolderPath: "/media/new/")
        #expect(edit.movedPath(from: try current(root: "/media/old", path: "/media/old/Big Buck Bunny (2008)")) == "/media/new/Big Buck Bunny (2008)")
    }

    @Test func theSameRootModuloSlashesDoesNotMove() throws {
        #expect(ArrRecordSettings(rootFolderPath: "/media/old/").movedPath(from: try current(root: "/media/old", path: "/media/old/x")) == nil)
        #expect(ArrRecordSettings(qualityProfileId: 4).movedPath(from: try current(root: "/media/old", path: "/media/old/x")) == nil)
    }

    @Test func mergeKeepsWhatTheEditLeavesNil() throws {
        var record = try current(root: "/media/old", path: "/media/old/x")
        record.merge(ArrRecordSettings(seasonFolder: false))
        #expect(record.qualityProfileId == 1 && record.seasonFolder == false && record.rootFolderPath == "/media/old")
    }
}
