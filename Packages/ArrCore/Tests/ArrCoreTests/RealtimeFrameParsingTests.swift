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

    @Test("A file-import invocation maps to fileImported + queueChanged")
    func fileImported() {
        let frame = #"{"type":1,"target":"receiveMessage","arguments":[{"body":{"action":"updated"},"name":"movieFile"}]}"#
        #expect(SignalRConnection.parse(frame: frame, source: .sonarr)
                == .events([.fileImported(source: .sonarr), .queueChanged(source: .sonarr)]))
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
