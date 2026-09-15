import Foundation
import Testing
@testable import MediaKit

@Suite struct SQLiteDatabaseTests {
    let key = ResourceKey(instance: InstanceID(.radarr), operation: "radarr.fetchQueue")
    let fingerprint = Fingerprint(baseURL: URL(string: "http://radarr.fixture.invalid:8080")!, generation: "g1")

    func entry(_ freshness: FreshnessClass = .live, at: Date = Date(timeIntervalSince1970: 1_800_000_000), tags: Set<InvalidationTag> = []) -> StoredEntry {
        StoredEntry(key: key, fingerprint: fingerprint, freshness: freshness, payload: Data("[]".utf8), fetchedAt: at, staleAt: at.addingTimeInterval(86_400), tags: tags)
    }

    @Test func schemaRefusesVolatileRows() async throws {
        let db = try SQLiteDatabase(location: .memory, log: NoLog())
        await #expect(throws: MediaKitError.self) { try await db.put([entry(.volatile)], lastUsed: Date()) }
        #expect(try await db.scalar("SELECT COUNT(*) FROM entries WHERE class = 0") == 0)
    }

    @Test func putReadMarkStaleRoundTrip() async throws {
        let db = try SQLiteDatabase(location: .memory, log: NoLog())
        let tag = InvalidationTag.collection(.queue, InstanceID(.radarr))
        try await db.put([entry(tags: [tag])], lastUsed: Date())
        let read = try await db.entry(key, fingerprint: fingerprint)
        #expect(read?.tags == [tag])
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        #expect(try await db.markStale(tags: [tag], at: now) == 1)
        #expect(try await db.entry(key, fingerprint: fingerprint)?.staleAt == now)
        #expect(try await db.entry(key, fingerprint: Fingerprint(baseURL: URL(string: "http://other")!, generation: "g1")) == nil)
    }

    @Test func walAndBusyTimeoutLetTwoConnectionsShareAFile() async throws {
        let dir = Temp.directory()
        let a = try SQLiteDatabase(location: .file(in: dir), log: NoLog())
        let b = try SQLiteDatabase(location: .file(in: dir), log: NoLog())
        try await a.put([entry()], lastUsed: Date())
        #expect(try await b.entry(key, fingerprint: fingerprint) != nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mediakit.sqlite-wal").path))
    }

    @Test func sweepExpiresByClassRetentionAndEvictsOverCap() async throws {
        let db = try SQLiteDatabase(location: .memory, log: NoLog())
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.put([entry(.live, at: old)], lastUsed: old)
        let report = try await db.sweep(now: old.addingTimeInterval(3 * 86_400 + 1), cap: 1 << 20, retention: { $0.retention })
        #expect(report.expired == 1)
        for i in 0..<20 {
            let k = ResourceKey(instance: InstanceID(.radarr), operation: "radarr.fetchQueue", discriminator: "i=\(i)")
            try await db.put([StoredEntry(key: k, fingerprint: fingerprint, freshness: .warm, payload: Data(repeating: 0, count: 1000), fetchedAt: old, staleAt: old.addingTimeInterval(1e9), tags: [])], lastUsed: old)
        }
        let evicted = try await db.sweep(now: old, cap: 5000, retention: { $0.retention })
        #expect(evicted.evicted > 0)
        #expect(try await db.scalar("SELECT COALESCE(SUM(bytes),0) FROM entries") <= 5000)
    }

    @Test func crosswalkAndCapabilitiesSurviveEntryPurge() async throws {
        let db = try SQLiteDatabase(location: .memory, log: NoLog())
        let radarr = InstanceID(.radarr)
        try await db.putCrosswalk([Crosswalk(from: .tmdbMovie(603), to: .arr(radarr, 15), kind: .movie, confidence: .asserted, source: .arrRecord, fetchedAt: Date())])
        try await db.putCapabilities(StoredCapabilities(instance: radarr, fingerprint: fingerprint, version: "6.0.0", capabilities: [], probedAt: Date(), origin: .probe))
        try await db.delete(freshness: nil)
        #expect(try await db.crosswalk(from: .arr(radarr, 15), kind: .movie).first?.to == .tmdbMovie(603))
        #expect(try await db.capabilities(radarr)?.version == "6.0.0")
        try await db.forgetCrosswalk(instance: radarr)
        #expect(try await db.crosswalk(from: .tmdbMovie(603), kind: .movie).isEmpty)
    }
}
