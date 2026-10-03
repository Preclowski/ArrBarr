import Foundation
import Testing
import MediaKit
@testable import ArrCore

@Suite("Release history marks")
struct ReleaseHistoryMarkTests {
    private static func records(_ json: String) throws -> [ArrHistoryRecord] {
        try JSONDecoder().decode([ArrHistoryRecord].self, from: Data(json.utf8))
    }

    @Test("A grab marks its guid; a later failure of that download turns it red; a regrab wins")
    func marks() throws {
        let marks = ReleaseHistoryMark.marks(from: try Self.records("""
        [
          {"id": 1, "eventType": "grabbed", "date": "2026-09-01T10:00:00Z", "downloadId": "A", "data": {"guid": "g-a"}},
          {"id": 2, "eventType": "downloadFailed", "date": "2026-09-01T11:00:00Z", "downloadId": "A", "data": {}},
          {"id": 3, "eventType": "grabbed", "date": "2026-09-02T10:00:00Z", "downloadId": "B", "data": {"guid": "g-b"}},
          {"id": 4, "eventType": "downloadFolderImported", "date": "2026-09-02T12:00:00Z", "downloadId": "B", "data": {}},
          {"id": 5, "eventType": "grabbed", "date": "2026-09-03T10:00:00Z", "downloadId": "C", "data": {"guid": "g-c"}},
          {"id": 6, "eventType": "downloadFailed", "date": "2026-09-03T11:00:00Z", "downloadId": "C", "data": {}},
          {"id": 7, "eventType": "grabbed", "date": "2026-09-04T10:00:00Z", "downloadId": "D", "data": {"guid": "g-c"}}
        ]
        """))
        #expect(marks["g-a"]?.event == .failed)
        #expect(marks["g-b"]?.event == .grabbed)
        #expect(marks["g-c"]?.event == .grabbed)
        #expect(marks.count == 3)
    }
}
