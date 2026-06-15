import Testing
import Foundation
@testable import ArrCore

@Suite("QueueAggregator.fetch")
@MainActor
struct QueueAggregatorTests {
    private func makeConfigStore() -> ConfigStore {
        let suiteName = "QueueAggregatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ConfigStore(defaults: defaults)
    }

    @Test("Unconfigured arrs do not surface a queue error")
    func unconfiguredArrsAreSilent() async {
        // Fresh store → every arr is unconfigured, so each client throws
        // `notConfigured` *before* any network call (no I/O in this test).
        // Those must NOT become user-visible queue errors — Upcoming/Health
        // already swallow them, and an unconfigured Lidarr/Whisparr showing
        // "Service not configured" in the queue is the bug.
        let aggregator = QueueAggregator(configStore: makeConfigStore())
        let result = await aggregator.fetch()
        #expect(result.radarrError == nil)
        #expect(result.sonarrError == nil)
        #expect(result.lidarrError == nil)
        #expect(result.whisparrError == nil)
    }
}

@Suite("QueueAggregator.isUnreachable")
struct QueueAggregatorReachabilityTests {
    @Test("Transport failures are unreachable")
    func transportIsUnreachable() {
        for code in [URLError.Code.cannotConnectToHost, .cannotFindHost,
                     .dnsLookupFailed, .timedOut, .notConnectedToInternet,
                     .networkConnectionLost] {
            #expect(QueueAggregator.isUnreachable(URLError(code)))
            #expect(QueueAggregator.isUnreachable(HTTPError.transport(URLError(code))))
        }
    }

    @Test("Gateway and wrong-endpoint statuses are unreachable (split-DNS / proxy)")
    func gatewayStatusesAreUnreachable() {
        for code in [404, 408, 410, 502, 503, 504, 522, 523, 524] {
            #expect(QueueAggregator.isUnreachable(HTTPError.status(code, body: nil)),
                    "HTTP \(code) should read as unreachable")
        }
    }

    @Test("Arr-origin statuses are NOT unreachable — the arr answered")
    func arrOriginStatusesAreReachable() {
        for code in [400, 401, 403, 422, 500] {
            #expect(!QueueAggregator.isUnreachable(HTTPError.status(code, body: nil)),
                    "HTTP \(code) is a service problem, not offline")
        }
    }

    @Test("A successful TLS handshake that then fails is not an unreachable signal")
    func tlsFailureIsReachable() {
        #expect(!QueueAggregator.isUnreachable(URLError(.secureConnectionFailed)))
    }
}
