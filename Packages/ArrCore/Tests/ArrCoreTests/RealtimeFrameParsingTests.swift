import Testing
@testable import ArrCore

/// Parsing tests for the SignalR Hub frames Sonarr/Radarr actually push.
/// The frames below are verbatim captures from a live Servarr SignalR hub
/// (Radarr 4.x / Sonarr 4.x over a reverse proxy). They pin the bug that
/// made realtime "not work": the resource `action` is nested inside `body`
/// (`arguments[0].body.action`), but the old parser required it at the top
/// level of the argument — so every event fell through to an ignored
/// `.other` and nothing ever refreshed.
@Suite("SignalR frame parsing")
struct RealtimeFrameParsingTests {
    private let sep = "\u{1E}"

    @Test("A queue invocation maps to queueChanged (action nested in body)")
    func queueInvocation() {
        let frame = #"{"type":1,"target":"receiveMessage","arguments":[{"body":{"action":"sync"},"name":"queue"}]}"#
        #expect(SignalRConnection.parse(frame: frame, source: .radarr)
                == .events([.queueChanged(source: .radarr)]))
    }

    /// The names here are the ones a live hub actually sends, captured off
    /// Radarr and Lidarr: **lowercase**. This test used to assert the
    /// camelCase spelling from the API docs (`movieFile`), which is why the
    /// mismatch survived — the parser and the test agreed with each other and
    /// disagreed with the wire, so `.fileImported` was never emitted in
    /// production for any source.
    @Test("A file-import invocation maps to fileImported + queueChanged",
          arguments: ["moviefile", "episodefile", "trackfile"])
    func fileImported(_ name: String) {
        let frame = #"{"type":1,"target":"receiveMessage","arguments":[{"body":{"action":"updated"},"name":"\#(name)"}]}"#
        #expect(SignalRConnection.parse(frame: frame, source: .sonarr)
                == .events([.fileImported(source: .sonarr), .queueChanged(source: .sonarr)]))
    }

    /// Belt and braces: whatever casing a future Servarr picks, the mapping
    /// holds.
    @Test("Resource names match regardless of casing")
    func nameCasingIsIgnored() {
        for name in ["movieFile", "MovieFile", "MOVIEFILE"] {
            let frame = #"{"type":1,"target":"receiveMessage","arguments":[{"body":{"action":"updated"},"name":"\#(name)"}]}"#
            #expect(SignalRConnection.parse(frame: frame, source: .radarr)
                    == .events([.fileImported(source: .radarr), .queueChanged(source: .radarr)]))
        }
        let queue = #"{"type":1,"target":"receiveMessage","arguments":[{"body":{"action":"sync"},"name":"Queue"}]}"#
        #expect(SignalRConnection.parse(frame: queue, source: .radarr)
                == .events([.queueChanged(source: .radarr)]))
    }

    /// `QueueStatusController` is the one Servarr broadcast that sends its
    /// resource inline (`ModelAction.Updated` *with* the body) rather than a
    /// payload-free `Sync`. That body is what lets a `queue` push be answered
    /// with nothing when the summary hasn't moved.
    @Test("A queue/status invocation carries the counters inline")
    func queueStatusCarriesResource() {
        let frame = #"{"type":1,"target":"receiveMessage","arguments":[{"body":{"action":"updated","resource":{"totalCount":7,"count":5,"unknownCount":2,"errors":true,"warnings":false}},"name":"queue/status"}]}"#
        guard case .events(let events) = SignalRConnection.parse(frame: frame, source: .lidarr),
              case .queueStatus(let source, let status) = events.first
        else { return #expect(Bool(false), "expected a queueStatus event") }

        #expect(source == .lidarr)
        #expect(status.totalCount == 7)
        #expect(status.count == 5)
        #expect(status.unknownCount == 2)
        #expect(status.errors == true)
        #expect(status.warnings == false)
    }

    /// A malformed or resource-less status frame must not be mistaken for a
    /// *zeroed* status — that would read as "the queue emptied" and could
    /// suppress a refresh that was genuinely needed.
    @Test("A queue/status frame without a resource degrades to .other")
    func queueStatusWithoutResource() {
        let frame = #"{"type":1,"target":"receiveMessage","arguments":[{"body":{"action":"updated"},"name":"queue/status"}]}"#
        #expect(SignalRConnection.parse(frame: frame, source: .lidarr)
                == .events([.other(source: .lidarr, name: "queue/status", action: "updated")]))
    }

    @Test("An unrecognised resource surfaces as .other, not dropped")
    func otherResource() {
        let frame = #"{"type":1,"target":"receiveMessage","arguments":[{"body":{"version":"4.0.17.2952"},"name":"version"}]}"#
        #expect(SignalRConnection.parse(frame: frame, source: .radarr)
                == .events([.other(source: .radarr, name: "version", action: "")]))
    }

    @Test("A frame with a trailing record separator parses the same")
    func trailingSeparator() {
        let frame = #"{"type":1,"target":"receiveMessage","arguments":[{"body":{"action":"sync"},"name":"queue"}]}"#
        #expect(SignalRConnection.parse(frame: frame, source: .radarr)
                == .events([.queueChanged(source: .radarr)]))
    }

    @Test("Ping (type 6) is ignored")
    func ping() {
        #expect(SignalRConnection.parse(frame: #"{"type":6}"#, source: .radarr) == .ignored)
    }

    @Test("Close (type 7) signals close so the loop reconnects")
    func close() {
        #expect(SignalRConnection.parse(frame: #"{"type":7}"#, source: .radarr) == .close)
    }

    @Test("Malformed JSON is ignored, not crashed on")
    func malformed() {
        #expect(SignalRConnection.parse(frame: "not json", source: .radarr) == .ignored)
        #expect(SignalRConnection.parse(frame: "", source: .radarr) == .ignored)
    }

    @Test("An envelope without arguments falls back to the hub target name")
    func noEnvelope() {
        let frame = #"{"type":1,"target":"receiveMessage"}"#
        #expect(SignalRConnection.parse(frame: frame, source: .radarr)
                == .events([.other(source: .radarr, name: "receiveMessage", action: "raw")]))
    }
}
