import Foundation
import Testing
@testable import MediaKit

@Suite struct PipelineTests {
    @Test func secretTravelsOnlyInTheHeader() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: "[]")
        let response = try await kit.pipeline.send(kit.plan("fetchQueue"))
        #expect(response.status == 200)
        let request = kit.transport.requests[0]
        #expect(request.headers["X-Api-Key"] == "secret-radarr")
        #expect(request.url.absoluteString == "http://radarr.fixture.invalid:8080/api/v3/queue")
        #expect(!ResourceKey(kit.plan("fetchQueue")).storageKey.contains("secret"))
    }

    @Test func notConfiguredInstanceNeverReachesTheTransport() async throws {
        let kit = try await TestKit(instances: [TestKit.radarr])
        await #expect(throws: MediaKitError.notConfigured(TestKit.sonarr)) {
            try await kit.pipeline.send(kit.plan("fetchQueue", instance: TestKit.sonarr))
        }
        #expect(kit.transport.count == 0)
    }

    @Test func idempotentReadRetriesThreeTimesThenUnreachable() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        kit.transport.fallback = { _ in throw URLError(.cannotConnectToHost) }
        let task = Task {
            do { _ = try await kit.pipeline.send(kit.plan("fetchQueue")); Issue.record("expected failure") }
            catch let error as MediaKitError { #expect(error.caseName == "unreachable") }
            catch { Issue.record("unexpected \(error)") }
        }
        for _ in 0..<2 {
            try await Task.sleep(for: .milliseconds(20))
            kit.clock.advance(by: .seconds(10))
        }
        await task.value
        #expect(kit.transport.count == 3)
    }

    @Test func writeIsNeverRetried() async throws {
        let kit = try await TestKit()
        kit.transport.fallback = { _ in throw URLError(.timedOut) }
        var plan = kit.plan("pause")
        plan.method = "POST"
        plan.retry = .never
        await #expect(throws: MediaKitError.self) { try await kit.pipeline.send(plan) }
        #expect(kit.transport.count == 1)
    }

    @Test func rejectionCarriesTheServerMessage() async throws {
        let kit = try await TestKit()
        kit.transport.answer("addMovie", json: #"[{"errorMessage":"This movie has already been added"}]"#, status: 400)
        var plan = kit.plan("addMovie", path: "/api/v3/movie")
        plan.method = "POST"
        do { _ = try await kit.pipeline.send(plan); Issue.record("expected rejection") }
        catch let error as MediaKitError {
            #expect(error.serverMessage == "This movie has already been added")
            if case let .rejected(_, status, _) = error { #expect(status == 400) } else { Issue.record("wrong case \(error)") }
        }
    }

    @Test func unauthorizedWithoutSessionSurfacesOnce() async throws {
        let kit = try await TestKit()
        kit.transport.fallback = { _ in ScriptedTransport.Answer(status: 401, body: Data(#"{"message":"Unauthorized"}"#.utf8)) }
        await #expect(throws: MediaKitError.unauthorized(TestKit.radarr, status: 401, serverMessage: "Unauthorized")) {
            try await kit.pipeline.send(kit.plan("fetchQueue"))
        }
        #expect(kit.transport.count == 1)
    }

    @Test func cancellationIsRethrownAsCancellationError() async throws {
        let kit = try await TestKit()
        kit.transport.delay = .seconds(5)
        let task = Task { try await kit.pipeline.send(kit.plan("fetchQueue")) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func retryAfterHeaderParses() {
        #expect(RequestPipeline.retryAfter("12", now: Date()) == .seconds(12))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = RequestPipeline.retryAfter("Sat, 16 Jan 2027 00:00:00 GMT", now: now)
        #expect(later != nil && later! > .seconds(1))
        #expect(RequestPipeline.retryAfter(nil, now: now) == nil)
    }
}
