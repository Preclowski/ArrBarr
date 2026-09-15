import Foundation
import SQLite3

public struct StoredEntry: Sendable {
    public let key: ResourceKey
    public let fingerprint: Fingerprint
    public let freshness: FreshnessClass
    public let payload: Data
    public let fetchedAt: Date
    public var staleAt: Date
    public let tags: Set<InvalidationTag>

    public init(key: ResourceKey, fingerprint: Fingerprint, freshness: FreshnessClass, payload: Data, fetchedAt: Date, staleAt: Date, tags: Set<InvalidationTag>) {
        self.key = key; self.fingerprint = fingerprint; self.freshness = freshness; self.payload = payload
        self.fetchedAt = fetchedAt; self.staleAt = staleAt; self.tags = tags
    }
}

public struct StoredCapabilities: Sendable, Equatable {
    public let instance: InstanceID
    public let fingerprint: Fingerprint
    public let version: String?
    public let capabilities: Set<Capability>
    public let probedAt: Date
    public let origin: CapabilitySet.Origin
}

public struct SweepReport: Sendable, Equatable {
    public var expired = 0, evicted = 0, vacuumed = false
}

public struct StoreStatistics: Sendable, Equatable {
    public var entries = 0, bytes = 0, crosswalk = 0, capabilities = 0, memoryEntries = 0, memoryBytes = 0
    public var readOnlyCache = false
    public init() {}
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let fileProtectionCompleteUntilFirstUserAuthentication: Int32 = 0x0030_0000

/// Pinned to its own serial queue so `sqlite3_step` never blocks the cooperative pool.
public actor SQLiteDatabase {
    public nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let connection: Connection
    private var db: OpaquePointer? { connection.db }
    private var statements: [String: OpaquePointer] {
        get { connection.statements }
        set { connection.statements = newValue }
    }
    public nonisolated let location: DatabaseLocation
    public private(set) var readOnlyCache: Bool
    private let log: any LogSink

    public init(location: DatabaseLocation, log: any LogSink) throws {
        self.location = location
        self.log = log
        self.readOnlyCache = location.readOnlyCache
        queue = DispatchSerialQueue(label: "pl.incred.mediakit.sqlite", qos: .utility)
        var handle: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let path: String
        switch location.kind {
        case .memory:
            path = ":memory:"
        case let .file(directory):
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent(location.fileName).path
            if location.protectFiles { flags |= fileProtectionCompleteUntilFirstUserAuthentication }
        }
        let isNew = path == ":memory:" || !FileManager.default.fileExists(atPath: path)
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw MediaKitError.persistence(detail: message)
        }
        connection = Connection(db: handle)
        sqlite3_busy_timeout(handle, 5000)
        if isNew { try Self.exec(handle, "PRAGMA auto_vacuum = INCREMENTAL;") }
        try Self.exec(handle, StoreSchema.pragmas)
        var version: Int32 = 0
        try Self.query(handle, "PRAGMA user_version;") { stmt in version = sqlite3_column_int(stmt, 0) }
        if version > StoreSchema.userVersion {
            readOnlyCache = true
            log.log(.notice, category: "Store", "database from a newer build (user_version \(version)); cache read-only")
        } else if version < StoreSchema.userVersion {
            try Self.exec(handle, StoreSchema.v1)
        }
    }

    /// Owns the handle so the actor's deinit touches no isolated state.
    private final class Connection {
        let db: OpaquePointer
        var statements: [String: OpaquePointer] = [:]
        init(db: OpaquePointer) { self.db = db }
        deinit {
            for stmt in statements.values { sqlite3_finalize(stmt) }
            sqlite3_close(db)
        }
    }

    // MARK: - Entries

    public func entry(_ key: ResourceKey, fingerprint: Fingerprint) throws -> StoredEntry? {
        try entries([key], fingerprint: fingerprint)[key]
    }

    public func entries(_ keys: [ResourceKey], fingerprint: Fingerprint) throws -> [ResourceKey: StoredEntry] {
        var out: [ResourceKey: StoredEntry] = [:]
        let stmt = try prepare("SELECT class, payload, fetched_at, stale_at FROM entries WHERE key = ? AND fingerprint = ?")
        let tagStmt = try prepare("SELECT tag FROM entry_tags WHERE entry_key = ?")
        for key in keys {
            bind(stmt, 1, key.storageKey); bind(stmt, 2, fingerprint.rawValue)
            defer { reset(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { continue }
            let freshness = FreshnessClass(rawValue: Int(sqlite3_column_int(stmt, 0))) ?? .warm
            let payload = column(stmt, 1)
            let fetchedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let staleAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            var tags = Set<InvalidationTag>()
            bind(tagStmt, 1, key.storageKey)
            while sqlite3_step(tagStmt) == SQLITE_ROW { tags.insert(InvalidationTag(rawValue: text(tagStmt, 0))) }
            reset(tagStmt)
            out[key] = StoredEntry(key: key, fingerprint: fingerprint, freshness: freshness, payload: payload, fetchedAt: fetchedAt, staleAt: staleAt, tags: tags)
        }
        return out
    }

    /// One transaction; refuses `.volatile` before binding.
    public func put(_ entries: [StoredEntry], lastUsed: Date) throws {
        guard !readOnlyCache else { return }
        if let bad = entries.first(where: { !$0.freshness.persists }) {
            log.log(.fault, category: "Store", "volatile row reached put: \(bad.key.operation)")
            throw MediaKitError.persistence(detail: "volatile entry \(bad.key.storageKey)")
        }
        let upsert = try prepare("""
        INSERT INTO entries (key, instance, fingerprint, operation, class, payload, bytes, fetched_at, stale_at, last_used)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET instance = excluded.instance, fingerprint = excluded.fingerprint, operation = excluded.operation,
            class = excluded.class, payload = excluded.payload, bytes = excluded.bytes, fetched_at = excluded.fetched_at,
            stale_at = excluded.stale_at, last_used = excluded.last_used
        """)
        let clearTags = try prepare("DELETE FROM entry_tags WHERE entry_key = ?")
        let addTag = try prepare("INSERT OR IGNORE INTO entry_tags (tag, entry_key) VALUES (?, ?)")
        try transaction {
            for e in entries {
                bind(upsert, 1, e.key.storageKey); bind(upsert, 2, e.key.instance.description); bind(upsert, 3, e.fingerprint.rawValue)
                bind(upsert, 4, e.key.operation.rawValue); sqlite3_bind_int(upsert, 5, Int32(e.freshness.rawValue))
                bind(upsert, 6, e.payload); sqlite3_bind_int64(upsert, 7, Int64(e.payload.count))
                sqlite3_bind_double(upsert, 8, e.fetchedAt.timeIntervalSince1970); sqlite3_bind_double(upsert, 9, e.staleAt.timeIntervalSince1970)
                sqlite3_bind_double(upsert, 10, lastUsed.timeIntervalSince1970)
                try step(upsert)
                bind(clearTags, 1, e.key.storageKey); try step(clearTags)
                for tag in e.tags {
                    bind(addTag, 1, tag.rawValue); bind(addTag, 2, e.key.storageKey); try step(addTag)
                }
            }
        }
    }

    @discardableResult
    public func markStale(tags: Set<InvalidationTag>, at date: Date) throws -> Int {
        guard !readOnlyCache, !tags.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: tags.count).joined(separator: ",")
        let stmt = try prepare("UPDATE entries SET stale_at = MIN(stale_at, ?) WHERE key IN (SELECT entry_key FROM entry_tags WHERE tag IN (\(placeholders)))", cache: false)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        for (i, tag) in tags.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() { bind(stmt, Int32(i + 2), tag.rawValue) }
        try step(stmt)
        return Int(sqlite3_changes(db))
    }

    @discardableResult
    public func markStale(instance: InstanceID, at date: Date) throws -> Int {
        guard !readOnlyCache else { return 0 }
        let stmt = try prepare("UPDATE entries SET stale_at = MIN(stale_at, ?) WHERE instance = ?")
        defer { reset(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970); bind(stmt, 2, instance.description)
        try step(stmt)
        return Int(sqlite3_changes(db))
    }

    public func touch(_ keys: [ResourceKey], at date: Date) throws {
        guard !readOnlyCache else { return }
        let stmt = try prepare("UPDATE entries SET last_used = ? WHERE key = ?")
        for key in keys {
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970); bind(stmt, 2, key.storageKey)
            try step(stmt); reset(stmt)
        }
    }

    public func delete(freshness: FreshnessClass?) throws {
        guard !readOnlyCache else { return }
        if let freshness {
            let stmt = try prepare("DELETE FROM entries WHERE class = ?")
            defer { reset(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(freshness.rawValue)); try step(stmt)
        } else {
            try Self.exec(db!, "DELETE FROM entries;")
        }
    }

    // MARK: - Live snapshots, capabilities, crosswalk

    public func lastKnown(instance: InstanceID, stream: String) throws -> (Data, Date)? {
        let stmt = try prepare("SELECT payload, captured_at FROM live_snapshots WHERE instance = ? AND stream = ?")
        defer { reset(stmt) }
        bind(stmt, 1, instance.description); bind(stmt, 2, stream)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (column(stmt, 0), Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)))
    }

    public func putLastKnown(instance: InstanceID, stream: String, payload: Data, at date: Date) throws {
        guard !readOnlyCache else { return }
        let stmt = try prepare("INSERT OR REPLACE INTO live_snapshots (instance, stream, payload, captured_at) VALUES (?, ?, ?, ?)")
        defer { reset(stmt) }
        bind(stmt, 1, instance.description); bind(stmt, 2, stream); bind(stmt, 3, payload); sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
        try step(stmt)
    }

    public func capabilities(_ instance: InstanceID) throws -> StoredCapabilities? {
        let stmt = try prepare("SELECT fingerprint, version, capabilities, probed_at, origin FROM capabilities WHERE instance = ?")
        defer { reset(stmt) }
        bind(stmt, 1, instance.description)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let caps = Set(text(stmt, 2).split(separator: " ").map { Capability(rawValue: String($0)) })
        return StoredCapabilities(instance: instance, fingerprint: Fingerprint(rawValue: text(stmt, 0)),
                                  version: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : text(stmt, 1),
                                  capabilities: caps, probedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                                  origin: CapabilitySet.Origin(rawValue: text(stmt, 4)) ?? .persisted)
    }

    public func putCapabilities(_ value: StoredCapabilities) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO capabilities (instance, fingerprint, version, capabilities, probed_at, origin) VALUES (?, ?, ?, ?, ?, ?)")
        defer { reset(stmt) }
        bind(stmt, 1, value.instance.description); bind(stmt, 2, value.fingerprint.rawValue)
        if let v = value.version { bind(stmt, 3, v) } else { sqlite3_bind_null(stmt, 3) }
        bind(stmt, 4, value.capabilities.map(\.rawValue).sorted().joined(separator: " "))
        sqlite3_bind_double(stmt, 5, value.probedAt.timeIntervalSince1970); bind(stmt, 6, value.origin.rawValue)
        try step(stmt)
    }

    public func crosswalk(from id: MediaID, kind: MediaKind?) throws -> [Crosswalk] {
        let stmt = try prepare("SELECT to_ns, to_value, kind, confidence, source, fetched_at FROM crosswalk WHERE from_ns = ? AND from_value = ?")
        defer { reset(stmt) }
        bind(stmt, 1, id.namespace.token); bind(stmt, 2, id.value)
        var out: [Crosswalk] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ns = IDNamespace(token: text(stmt, 0)), let k = MediaKind(rawValue: text(stmt, 2)),
                  let confidence = Crosswalk.Confidence(rawValue: Int(sqlite3_column_int(stmt, 3))),
                  let source = Crosswalk.Source(rawValue: text(stmt, 4)) else { continue }
            if let kind, k != kind { continue }
            out.append(Crosswalk(from: id, to: MediaID(namespace: ns, value: text(stmt, 1)), kind: k, confidence: confidence, source: source,
                                 fetchedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))))
        }
        return out
    }

    /// Both directions; a higher confidence wins over an existing edge.
    public func putCrosswalk(_ edges: [Crosswalk]) throws {
        let stmt = try prepare("""
        INSERT INTO crosswalk (from_ns, from_value, to_ns, to_value, kind, confidence, source, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(from_ns, from_value, to_ns, kind) DO UPDATE SET to_value = excluded.to_value, confidence = excluded.confidence,
            source = excluded.source, fetched_at = excluded.fetched_at WHERE excluded.confidence >= crosswalk.confidence
        """)
        try transaction {
            for edge in edges.flatMap({ [$0, $0.reversed] }) {
                bind(stmt, 1, edge.from.namespace.token); bind(stmt, 2, edge.from.value); bind(stmt, 3, edge.to.namespace.token); bind(stmt, 4, edge.to.value)
                bind(stmt, 5, edge.kind.rawValue); sqlite3_bind_int(stmt, 6, Int32(edge.confidence.rawValue)); bind(stmt, 7, edge.source.rawValue)
                sqlite3_bind_double(stmt, 8, edge.fetchedAt.timeIntervalSince1970)
                try step(stmt); reset(stmt)
            }
        }
    }

    public func forgetCrosswalk(instance: InstanceID) throws {
        let stmt = try prepare("DELETE FROM crosswalk WHERE from_ns IN (?, ?) OR to_ns IN (?, ?)")
        defer { reset(stmt) }
        let arr = IDNamespace.arr(instance).token, server = IDNamespace.mediaServer(instance).token
        bind(stmt, 1, arr); bind(stmt, 2, server); bind(stmt, 3, arr); bind(stmt, 4, server)
        try step(stmt)
    }

    // MARK: - Maintenance

    public func sweep(now: Date, cap: Int, retention: (FreshnessClass) -> Duration) throws -> SweepReport {
        var report = SweepReport()
        guard !readOnlyCache else { return report }
        let expire = try prepare("DELETE FROM entries WHERE rowid IN (SELECT rowid FROM entries WHERE class = ? AND stale_at < ? LIMIT 200)")
        for freshness in FreshnessClass.allCases where freshness.persists {
            repeat {
                sqlite3_bind_int(expire, 1, Int32(freshness.rawValue))
                sqlite3_bind_double(expire, 2, now.addingTimeInterval(-retention(freshness).seconds).timeIntervalSince1970)
                try step(expire); reset(expire)
                let changed = Int(sqlite3_changes(db))
                report.expired += changed
                if changed < 200 { break }
            } while true
        }
        let evict = try prepare("DELETE FROM entries WHERE rowid IN (SELECT rowid FROM entries ORDER BY class ASC, last_used ASC LIMIT 50)")
        while try totalBytes() > cap {
            try step(evict); reset(evict)
            let changed = Int(sqlite3_changes(db))
            report.evicted += changed
            if changed == 0 { break }
            if try totalBytes() <= cap * 9 / 10 { break }
        }
        var freelist: Int32 = 0, pages: Int32 = 1
        try Self.query(db!, "PRAGMA freelist_count;") { freelist = sqlite3_column_int($0, 0) }
        try Self.query(db!, "PRAGMA page_count;") { pages = sqlite3_column_int($0, 0) }
        if pages > 0, freelist * 4 > pages {
            try Self.exec(db!, "PRAGMA incremental_vacuum(64);")
            report.vacuumed = true
        }
        return report
    }

    public func statistics() throws -> StoreStatistics {
        var s = StoreStatistics()
        s.readOnlyCache = readOnlyCache
        try Self.query(db!, "SELECT COUNT(*), COALESCE(SUM(bytes), 0) FROM entries;") { s.entries = Int(sqlite3_column_int64($0, 0)); s.bytes = Int(sqlite3_column_int64($0, 1)) }
        try Self.query(db!, "SELECT COUNT(*) FROM crosswalk;") { s.crosswalk = Int(sqlite3_column_int64($0, 0)) }
        try Self.query(db!, "SELECT COUNT(*) FROM capabilities;") { s.capabilities = Int(sqlite3_column_int64($0, 0)) }
        return s
    }

    /// Test hook: `SELECT COUNT(*) FROM entries WHERE class = 0` and friends.
    public func scalar(_ sql: String) throws -> Int {
        var value = 0
        try Self.query(db!, sql) { value = Int(sqlite3_column_int64($0, 0)) }
        return value
    }

    private func totalBytes() throws -> Int { try scalar("SELECT COALESCE(SUM(bytes), 0) FROM entries;") }

    // MARK: - Plumbing

    private func transaction(_ body: () throws -> Void) throws {
        try Self.exec(db!, "BEGIN IMMEDIATE;")
        do { try body() } catch { try? Self.exec(db!, "ROLLBACK;"); throw error }
        try Self.exec(db!, "COMMIT;")
    }

    private func prepare(_ sql: String, cache: Bool = true) throws -> OpaquePointer {
        if cache, let cached = statements[sql] { return cached }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MediaKitError.persistence(detail: "prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        if cache { statements[sql] = stmt }
        return stmt
    }

    private func step(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            let message = String(cString: sqlite3_errmsg(db))
            reset(stmt)
            throw MediaKitError.persistence(detail: "step: \(message)")
        }
        if rc == SQLITE_DONE { reset(stmt) }
    }

    private func reset(_ stmt: OpaquePointer) { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String) { sqlite3_bind_text(stmt, index, value, -1, sqliteTransient) }
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Data) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(value.count), sqliteTransient) }
    }
    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String { sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? "" }
    private func column(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(message)
            throw MediaKitError.persistence(detail: text)
        }
    }

    private static func query(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MediaKitError.persistence(detail: "prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
}

extension Fingerprint {
    init(rawValue: String) { self.rawValue = rawValue }
}
