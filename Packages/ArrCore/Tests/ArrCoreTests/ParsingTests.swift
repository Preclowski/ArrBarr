import Testing
import Foundation
@testable import ArrCore

@Suite("Date Parsing")
struct DateParsingTests {
    @Test("Parses ISO8601 with fractional seconds")
    func fractionalSeconds() {
        let date = parseArrDate("2024-03-15T14:30:00.1234567Z")
        #expect(date != nil)
        let cal = Calendar.current
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date!)
        #expect(comps.year == 2024)
        #expect(comps.month == 3)
        #expect(comps.day == 15)
        #expect(comps.hour == 14)
        #expect(comps.minute == 30)
    }

    @Test("Parses ISO8601 without fractional seconds")
    func internetDateTime() {
        let date = parseArrDate("2024-03-15T14:30:00Z")
        #expect(date != nil)
    }

    @Test("Parses date-only format")
    func dateOnly() {
        let date = parseArrDate("2024-03-15")
        #expect(date != nil)
    }

    @Test("Returns nil for invalid strings")
    func invalid() {
        #expect(parseArrDate("not-a-date") == nil)
        #expect(parseArrDate("") == nil)
    }

    /// `parseArrDate` is called from SwiftUI *body getters* (`EpisodeRow.hasAired`
    /// runs it twice per row, every layout pass), so a per-call `ISO8601DateFormatter`
    /// — which builds an ICU formatter, four times over for the four format
    /// shapes — turns a 22-row season list into a stalled main thread.
    /// A season screen re-renders on every queue tick: ~70 parses per pass have
    /// to stay in the microsecond range, not the millisecond one.
    @Test("Parsing is cheap enough to run from a view body")
    func parsingIsCheap() {
        // The shapes an arr actually puts on the wire, including the worst case
        // (date-only), which only resolves after the three earlier attempts miss.
        let samples = [
            "2024-03-15T14:30:00.1234567Z",
            "2024-03-15T14:30:00Z",
            "2024-03-15T14:30:00",
            "2024-03-15",
        ]
        let iterations = 2_000
        let start = ContinuousClock.now
        for i in 0..<iterations {
            _ = parseArrDate(samples[i % samples.count])
        }
        let elapsed = ContinuousClock.now - start
        // A screen re-parses the SAME handful of strings, so this is the memo's
        // budget, not ICU's: cached formatters alone landed at ~15 µs/parse
        // (118 ms here) and a fresh formatter per call at ~50 µs (413 ms).
        #expect(elapsed < .milliseconds(30), "8k parses took \(elapsed)")
    }
}

@Suite("Protocol Parsing")
struct ProtocolParsingTests {
    @Test("Parses usenet (case-insensitive)")
    func usenet() {
        #expect(parseProtocol("usenet") == .usenet)
        #expect(parseProtocol("Usenet") == .usenet)
        #expect(parseProtocol("USENET") == .usenet)
    }

    @Test("Parses torrent (case-insensitive)")
    func torrent() {
        #expect(parseProtocol("torrent") == .torrent)
        #expect(parseProtocol("Torrent") == .torrent)
    }

    /// Lidarr's /queue serialises the .NET type name, not the plain form
    /// Radarr/Sonarr use. `.unknown` here silently strips pause/resume from
    /// every Lidarr row (no download client resolves for the protocol).
    @Test("Parses Lidarr's .NET type-name spellings")
    func lidarrTypeNames() {
        #expect(parseProtocol("TorrentDownloadProtocol") == .torrent)
        #expect(parseProtocol("UsenetDownloadProtocol") == .usenet)
    }

    @Test("Returns unknown for nil or unrecognized")
    func unknown() {
        #expect(parseProtocol(nil) == .unknown)
        #expect(parseProtocol("") == .unknown)
        #expect(parseProtocol("ftp") == .unknown)
    }
}

@Suite("Status Parsing")
struct StatusParsingTests {
    @Test("Paused always takes priority over tracked state")
    func pausedPriority() {
        #expect(parseStatus(arrStatus: "paused", trackedState: "downloading") == .paused)
        #expect(parseStatus(arrStatus: "paused", trackedState: nil) == .paused)
        #expect(parseStatus(arrStatus: "Paused", trackedState: "importing") == .paused)
    }

    @Test("Tracked state: downloading")
    func trackedDownloading() {
        #expect(parseStatus(arrStatus: nil, trackedState: "downloading") == .downloading)
        #expect(parseStatus(arrStatus: "queued", trackedState: "downloading") == .downloading)
    }

    @Test("Tracked state: failure variants")
    func trackedFailures() {
        #expect(parseStatus(arrStatus: nil, trackedState: "downloadFailed") == .failed)
        #expect(parseStatus(arrStatus: nil, trackedState: "failedPending") == .failed)
    }

    @Test("Tracked state: importing variants")
    func trackedImporting() {
        #expect(parseStatus(arrStatus: nil, trackedState: "importing") == .importing)
        #expect(parseStatus(arrStatus: nil, trackedState: "importPending") == .importing)
        #expect(parseStatus(arrStatus: nil, trackedState: "importPending", trackedStatus: "ok") == .importing)
        // Stuck import: the arr wants a manual import — that's a warning, not progress.
        #expect(parseStatus(arrStatus: "completed", trackedState: "importPending", trackedStatus: "warning") == .warning)
        #expect(parseStatus(arrStatus: nil, trackedState: "importing", trackedStatus: "Warning") == .warning)
    }

    @Test("Tracked state: imported is completed")
    func trackedCompleted() {
        #expect(parseStatus(arrStatus: nil, trackedState: "imported") == .completed)
    }

    @Test("Tracked state: importBlocked is warning")
    func trackedImportBlocked() {
        #expect(parseStatus(arrStatus: nil, trackedState: "importBlocked") == .warning)
    }

    @Test("Arr status fallbacks when tracked state is nil")
    func arrFallbacks() {
        #expect(parseStatus(arrStatus: "downloading", trackedState: nil) == .downloading)
        #expect(parseStatus(arrStatus: "queued", trackedState: nil) == .queued)
        #expect(parseStatus(arrStatus: "delay", trackedState: nil) == .queued)
        #expect(parseStatus(arrStatus: "completed", trackedState: nil) == .completed)
        #expect(parseStatus(arrStatus: "warning", trackedState: nil) == .warning)
        #expect(parseStatus(arrStatus: "failed", trackedState: nil) == .failed)
    }

    @Test("Unknown for nil or unrecognized values")
    func unknown() {
        #expect(parseStatus(arrStatus: nil, trackedState: nil) == .unknown)
        #expect(parseStatus(arrStatus: "something", trackedState: nil) == .unknown)
        #expect(parseStatus(arrStatus: "", trackedState: "") == .unknown)
    }
}
