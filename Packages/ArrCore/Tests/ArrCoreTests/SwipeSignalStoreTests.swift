import Foundation
import Testing
@testable import ArrCore

@MainActor
@Suite("Swipe signal store")
struct SwipeSignalStoreTests {

    private func freshStore() -> SwipeSignalStore {
        let suite = "SwipeSignalStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SwipeSignalStore(defaults: defaults)
    }

    @Test("A skip cools down for 14 days, then the title returns")
    func skipCoolsDownThenExpires() {
        let store = freshStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.record(key: "tmdb:1", title: "La La Land", kind: .skipped, now: t0)
        #expect(store.suppressedKeys(now: t0.addingTimeInterval(13 * 24 * 3600)).contains("tmdb:1"))
        #expect(!store.suppressedKeys(now: t0.addingTimeInterval(15 * 24 * 3600)).contains("tmdb:1"))
    }

    @Test("A second skip escalates the cooldown to 90 days")
    func repeatSkipEscalates() {
        let store = freshStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.record(key: "tmdb:1", title: "La La Land", kind: .skipped, now: t0)
        let t1 = t0.addingTimeInterval(20 * 24 * 3600)
        store.record(key: "tmdb:1", title: "La La Land", kind: .skipped, now: t1)
        #expect(store.suppressedKeys(now: t1.addingTimeInterval(60 * 24 * 3600)).contains("tmdb:1"))
        #expect(!store.suppressedKeys(now: t1.addingTimeInterval(91 * 24 * 3600)).contains("tmdb:1"))
    }

    @Test("Keeping a title clears its skip; a veto survives a later skip")
    func keptClearsSkipVetoSticks() {
        let store = freshStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.record(key: "tmdb:1", title: "Sicario", kind: .skipped, now: t0)
        store.record(key: "tmdb:1", title: "Sicario", kind: .kept, now: t0)
        #expect(!store.isSuppressed("tmdb:1", now: t0))

        store.record(key: "tmdb:2", title: "Cats", kind: .veto, now: t0)
        store.record(key: "tmdb:2", title: "Cats", kind: .skipped, now: t0)
        #expect(store.isSuppressed("tmdb:2", now: t0.addingTimeInterval(400 * 24 * 3600)),
                "a veto never expires and a skip must not downgrade it")
    }

    @Test("Reset clears skips but not vetoes; remove drops a single row")
    func resetAndRemove() {
        let store = freshStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.record(key: "tmdb:1", title: "A", kind: .skipped, now: t0)
        store.record(key: "tmdb:2", title: "B", kind: .veto, now: t0)
        store.resetSkips()
        #expect(!store.isSuppressed("tmdb:1", now: t0))
        #expect(store.isSuppressed("tmdb:2", now: t0))
        store.remove(key: "tmdb:2")
        #expect(!store.isSuppressed("tmdb:2", now: t0))
    }

    @Test("The cap evicts the oldest skips first and spares vetoes")
    func capSparesVetoes() {
        let store = freshStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.record(key: "veto:0", title: "V", kind: .veto, now: t0)
        for i in 1...520 {
            store.record(key: "tmdb:\(i)", title: "T\(i)", kind: .skipped,
                         now: t0.addingTimeInterval(Double(i)))
        }
        #expect(store.all.count <= 500 + 1)
        #expect(store.isSuppressed("veto:0", now: t0.addingTimeInterval(1000)),
                "the veto must survive cap eviction")
        #expect(!store.isSuppressed("tmdb:1", now: t0.addingTimeInterval(1000)),
                "the oldest skip should have been evicted")
    }

    @Test("Signals survive a store reload from the same defaults")
    func persistsAcrossReload() {
        let suite = "SwipeSignalStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let store = SwipeSignalStore(defaults: defaults)
        store.record(key: "tmdb:1", title: "A", kind: .skipped, now: t0)
        let reloaded = SwipeSignalStore(defaults: defaults)
        #expect(reloaded.isSuppressed("tmdb:1", now: t0))
    }
}
