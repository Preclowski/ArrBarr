import Foundation
import Testing
@testable import MediaKit

@Suite struct SignalRFrameTests {
    let radarr = InstanceID(.radarr), sonarr = InstanceID(.sonarr), lidarr = InstanceID(.lidarr)
    func invocation(_ name: String, _ body: String) -> String { #"{"type":1,"target":"receiveMessage","arguments":[{"body":\#(body),"name":"\#(name)"}]}"# }

    @Test func queueInvocationMapsToQueueChanged() {
        #expect(SignalRSource.parse(frame: invocation("queue", #"{"action":"sync"}"#), instance: radarr) == .events([.queueChanged(radarr)]))
    }

    @Test func fileImportsCarryTheKind() {
        #expect(SignalRSource.parse(frame: invocation("episodefile", #"{"action":"updated","resource":{"seriesId":9}}"#), instance: sonarr)
                == .events([.fileImported(sonarr, kind: .series, entityID: 9)]))
        #expect(SignalRSource.parse(frame: invocation("MovieFile", #"{"action":"updated"}"#), instance: radarr)
                == .events([.fileImported(radarr, kind: .movie, entityID: nil)]))
        #expect(SignalRSource.parse(frame: invocation("trackfile", #"{"action":"updated","resource":{"albumId":3}}"#), instance: lidarr)
                == .events([.fileImported(lidarr, kind: .album, entityID: 3)]))
    }

    @Test func queueStatusCarriesCounters() {
        let frame = invocation("queue/status", #"{"action":"updated","resource":{"totalCount":7,"count":5,"unknownCount":2,"errors":true,"warnings":false}}"#)
        #expect(SignalRSource.parse(frame: frame, instance: lidarr)
                == .events([.queueStatus(lidarr, QueueCounts(total: 7, count: 5, unknown: 2, errors: true, warnings: false))]))
    }

    @Test func queueStatusWithoutResourceDegradesToOther() {
        #expect(SignalRSource.parse(frame: invocation("queue/status", #"{"action":"updated"}"#), instance: lidarr)
                == .events([.other(lidarr, resource: "queue/status", action: "updated")]))
    }

    @Test func unrecognisedResourceSurfacesAsOther() {
        #expect(SignalRSource.parse(frame: invocation("version", #"{"version":"4.0.17.2952"}"#), instance: radarr)
                == .events([.other(radarr, resource: "version", action: "")]))
    }

    @Test func trailingRecordSeparatorParsesTheSame() {
        #expect(SignalRSource.parse(frame: invocation("queue", #"{"action":"sync"}"#) + "\u{1E}", instance: radarr) == .events([.queueChanged(radarr)]))
    }

    @Test func pingCloseAndGarbage() {
        #expect(SignalRSource.parse(frame: #"{"type":6}"#, instance: radarr) == .ignored)
        #expect(SignalRSource.parse(frame: #"{"type":7}"#, instance: radarr) == .close)
        #expect(SignalRSource.parse(frame: "not json", instance: radarr) == .ignored)
        #expect(SignalRSource.parse(frame: "", instance: radarr) == .ignored)
    }

    @Test func envelopeWithoutArgumentsFallsBackToTarget() {
        #expect(SignalRSource.parse(frame: #"{"type":1,"target":"receiveMessage"}"#, instance: radarr)
                == .events([.other(radarr, resource: "receiveMessage", action: "raw")]))
    }

    @Test func entityAndCommandEvents() {
        #expect(SignalRSource.parse(frame: invocation("series", #"{"action":"updated","resource":{"id":12}}"#), instance: sonarr)
                == .events([.entityChanged(sonarr, kind: .series, entityID: 12)]))
        #expect(SignalRSource.parse(frame: invocation("command", #"{"action":"updated","resource":{"name":"MoviesSearch","status":"completed"}}"#), instance: radarr)
                == .events([.commandFinished(radarr, name: "MoviesSearch")]))
        #expect(SignalRSource.parse(frame: invocation("command", #"{"action":"updated","resource":{"name":"RssSync","status":"started"}}"#), instance: radarr)
                == .events([.other(radarr, resource: "command", action: "updated")]))
    }

    @Test func tagMapKeepsTheStatusSkip() {
        let map = EventTagMap()
        let counts = QueueCounts(total: 1, count: 1, unknown: 0, errors: false, warnings: false)
        #expect(map.tags(for: .queueStatus(radarr, counts), lastCounts: counts).isEmpty)
        #expect(map.tags(for: .queueStatus(radarr, counts), lastCounts: nil) == [.collection(.queue, radarr)])
        #expect(map.tags(for: .fileImported(radarr, kind: .movie, entityID: 5), lastCounts: nil).contains(.entity(radarr, .movie, 5)))
        #expect(map.tags(for: .commandFinished(radarr, name: "MoviesSearch"), lastCounts: nil).contains(.collection(.queue, radarr)))
    }

    @Test func liveHubEndToEnd() async throws {
        let kit = try await TestKit()
        kit.transport.answer("realtime.negotiate", json: #"{"connectionId":"abc","connectionToken":"tok"}"#)
        kit.transport.frames = ["{}\u{1E}", #"{"type":1,"target":"receiveMessage","arguments":[{"body":{"action":"sync"},"name":"queue"}]}"# + "\u{1E}"]
        let hub = EventHub(store: kit.store, clock: kit.clock)
        let events = await hub.events()
        let source = SignalRSource(instance: TestKit.radarr, pipeline: kit.pipeline, clock: kit.clock, log: NoLog())
        await hub.attach(source, for: TestKit.radarr)
        var seen: [DataEvent] = []
        for await event in events {
            seen.append(event)
            if seen.count == 2 { break }
        }
        #expect(seen == [.queueChanged(TestKit.radarr), .queueChanged(TestKit.radarr)])
        let upgrade = kit.transport.requests.first { $0.operation.name == "realtime.connect" }
        #expect(upgrade?.url.query?.contains("access_token=secret-radarr") == true)
        #expect(upgrade?.url.query?.contains("id=tok") == true)
        #expect(Redaction.standard.loggableURL(upgrade!.url).contains("secret") == false)
        await hub.detach(TestKit.radarr)
    }
}
