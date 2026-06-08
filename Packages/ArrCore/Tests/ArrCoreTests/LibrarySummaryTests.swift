import Testing
import Foundation
@testable import ArrCore

@Suite("Library summary summation")
struct LibrarySummaryTests {
    @Test("Radarr summary counts records and sums sizeOnDisk")
    func radarr() throws {
        let recs = [
            try JSONDecoder().decode(RadarrLibraryRecord.self, from: #"{"id":1,"sizeOnDisk":100}"#.data(using: .utf8)!),
            try JSONDecoder().decode(RadarrLibraryRecord.self, from: #"{"id":2,"sizeOnDisk":250}"#.data(using: .utf8)!),
            try JSONDecoder().decode(RadarrLibraryRecord.self, from: #"{"id":3}"#.data(using: .utf8)!),
        ]
        let s = LibrarySummary.radarr(from: recs)
        #expect(s.source == .radarr)
        #expect(s.count == 3)
        #expect(s.totalBytes == 350)
    }

    @Test("Sonarr summary sums per-series statistics size")
    func sonarr() throws {
        let recs = [
            try JSONDecoder().decode(SonarrLibraryRecord.self, from: #"{"id":1,"statistics":{"sizeOnDisk":1000}}"#.data(using: .utf8)!),
            try JSONDecoder().decode(SonarrLibraryRecord.self, from: #"{"id":2,"statistics":{"sizeOnDisk":500}}"#.data(using: .utf8)!),
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
            try JSONDecoder().decode(WhisparrLibraryRecord.self, from: #"{"id":1,"sizeOnDisk":42}"#.data(using: .utf8)!),
        ]
        let s = LibrarySummary.whisparr(from: recs)
        #expect(s.source == .whisparr)
        #expect(s.totalBytes == 42)
    }
}
