import Testing
import Foundation
import MediaKit
@testable import ArrCore

@Suite("Library summary summation")
struct LibrarySummaryTests {
    @Test("Radarr summary counts records and sums sizeOnDisk")
    func radarr() throws {
        let recs = [
            try JSONDecoder().decode(ArrMovie.self, from: #"{"id":1,"title":"Big Buck Bunny","sizeOnDisk":100}"#.data(using: .utf8)!),
            try JSONDecoder().decode(ArrMovie.self, from: #"{"id":2,"title":"Big Buck Bunny","sizeOnDisk":250}"#.data(using: .utf8)!),
            try JSONDecoder().decode(ArrMovie.self, from: #"{"id":3,"title":"Big Buck Bunny"}"#.data(using: .utf8)!),
        ]
        let s = LibrarySummary.radarr(from: recs)
        #expect(s.source == .radarr)
        #expect(s.count == 3)
        #expect(s.totalBytes == 350)
    }

    @Test("Sonarr summary sums per-series statistics size")
    func sonarr() throws {
        let recs = [
            try JSONDecoder().decode(ArrSeries.self, from: #"{"id":1,"title":"Big Buck Bunny","statistics":{"sizeOnDisk":1000}}"#.data(using: .utf8)!),
            try JSONDecoder().decode(ArrSeries.self, from: #"{"id":2,"title":"Big Buck Bunny","statistics":{"sizeOnDisk":500}}"#.data(using: .utf8)!),
        ]
        let s = LibrarySummary.sonarr(from: recs)
        #expect(s.count == 2)
        #expect(s.totalBytes == 1500)
    }

    @Test("Lidarr summary sums per-artist statistics size")
    func lidarr() throws {
        let recs = [
            try JSONDecoder().decode(LidarrLibraryRecord.self, from: #"{"artistName":"A","statistics":{"sizeOnDisk":700}}"#.data(using: .utf8)!),
        ]
        let s = LibrarySummary.lidarr(from: recs)
        #expect(s.count == 1)
        #expect(s.totalBytes == 700)
    }

    @Test("Whisparr summary mirrors Radarr shape")
    func whisparr() throws {
        let recs = [
            try JSONDecoder().decode(ArrMovie.self, from: #"{"id":1,"title":"Big Buck Bunny","sizeOnDisk":42}"#.data(using: .utf8)!),
        ]
        let s = LibrarySummary.whisparr(from: recs)
        #expect(s.source == .whisparr)
        #expect(s.totalBytes == 42)
    }
}
