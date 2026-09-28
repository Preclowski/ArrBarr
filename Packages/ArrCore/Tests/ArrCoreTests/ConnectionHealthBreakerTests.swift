import Testing
import Foundation
@testable import ArrCore

@Suite("ConnectionHealth breaker merge")
@MainActor
struct ConnectionHealthBreakerTests {

    @Test("An open breaker shows down at once, before any strike is recorded")
    func openBreakerIsDownImmediately() {
        let health = ConnectionHealth()
        health.record(.arr(.sonarr), success: true, detail: "4.0", message: nil)
        health.noteBreakers([.arr(.sonarr)])
        #expect(health.state(for: .arr(.sonarr)).isDown)
        #expect(health.state(for: .arr(.radarr)) == .unknown)
    }

    @Test("Closing the breaker hands back the recorded state")
    func closedBreakerRestoresRecorded() {
        let health = ConnectionHealth()
        health.record(.tmdb, success: true, detail: nil, message: nil)
        health.noteBreakers([.tmdb])
        health.noteBreakers([])
        #expect(health.state(for: .tmdb) == .ok(detail: nil))
    }

    @Test("A recorded failure keeps its own message while the breaker is open")
    func recordedDownWins() {
        let recorded = ServiceHealthSnapshot(state: .down(message: "401 Unauthorized"))
        #expect(ConnectionHealth.merged(recorded, breakerOpen: true) == recorded)
        let ok = ServiceHealthSnapshot(state: .ok(detail: nil))
        #expect(ConnectionHealth.merged(ok, breakerOpen: false) == ok)
        #expect(ConnectionHealth.merged(.unknown, breakerOpen: true).state.isDown)
    }

    @Test("A queue failure below the strike threshold stays up unless the breaker says otherwise")
    func strikesStillDebounceWithoutBreaker() {
        let health = ConnectionHealth()
        health.record(.arr(.radarr), success: true, detail: nil, message: nil)
        health.record(.arr(.radarr), success: false, detail: nil, message: "timeout")
        #expect(!health.state(for: .arr(.radarr)).isDown)
        health.noteBreakers([.arr(.radarr)])
        #expect(health.state(for: .arr(.radarr)).isDown)
    }
}

private extension ConnectionHealthState {
    var isDown: Bool { if case .down = self { true } else { false } }
}
