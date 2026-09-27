import Foundation

public struct DatabaseLocation: Sendable {
    public enum Kind: Sendable { case file(directory: URL), memory }
    public let kind: Kind
    public let fileName: String
    public let protectFiles: Bool
    public let diskCap: Int
    public let readOnlyCache: Bool

    public init(kind: Kind, fileName: String = "mediakit.sqlite", protectFiles: Bool = false,
                diskCap: Int = 64 << 20, readOnlyCache: Bool = false) {
        self.kind = kind; self.fileName = fileName; self.protectFiles = protectFiles; self.diskCap = diskCap; self.readOnlyCache = readOnlyCache
    }

    public static let memory = DatabaseLocation(kind: .memory)
    public static func file(in directory: URL, protectFiles: Bool = false, diskCap: Int = 64 << 20, readOnlyCache: Bool = false) -> DatabaseLocation {
        DatabaseLocation(kind: .file(directory: directory), protectFiles: protectFiles, diskCap: diskCap, readOnlyCache: readOnlyCache)
    }
}

enum StoreSchema {
    static let userVersion: Int32 = 1

    static let pragmas = """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA busy_timeout = 5000;
    PRAGMA foreign_keys = ON;
    PRAGMA temp_store = MEMORY;
    PRAGMA wal_autocheckpoint = 256;
    """

    /// entries/entry_tags are a cache and may be dropped by a migration; the other tables never are.
    static let v1 = """
    CREATE TABLE IF NOT EXISTS entries (
        key TEXT PRIMARY KEY NOT NULL,
        instance TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        operation TEXT NOT NULL,
        class INTEGER NOT NULL CHECK (class > 0),
        payload BLOB NOT NULL,
        bytes INTEGER NOT NULL,
        fetched_at REAL NOT NULL,
        stale_at REAL NOT NULL,
        last_used REAL NOT NULL
    ) STRICT;
    CREATE INDEX IF NOT EXISTS entries_sweep ON entries(class, last_used);
    CREATE INDEX IF NOT EXISTS entries_instance ON entries(instance, fingerprint);
    CREATE TABLE IF NOT EXISTS entry_tags (
        tag TEXT NOT NULL,
        entry_key TEXT NOT NULL REFERENCES entries(key) ON DELETE CASCADE,
        PRIMARY KEY (tag, entry_key)
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS entry_tags_key ON entry_tags(entry_key);
    CREATE TABLE IF NOT EXISTS capabilities (
        instance TEXT PRIMARY KEY NOT NULL,
        fingerprint TEXT NOT NULL,
        version TEXT,
        capabilities TEXT NOT NULL,
        probed_at REAL NOT NULL,
        origin TEXT NOT NULL
    ) STRICT;
    CREATE TABLE IF NOT EXISTS crosswalk (
        from_ns TEXT NOT NULL, from_value TEXT NOT NULL,
        to_ns TEXT NOT NULL, to_value TEXT NOT NULL,
        kind TEXT NOT NULL,
        confidence INTEGER NOT NULL,
        source TEXT NOT NULL,
        fetched_at REAL NOT NULL,
        PRIMARY KEY (from_ns, from_value, to_ns, kind)
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS crosswalk_reverse ON crosswalk(to_ns, to_value, kind);
    CREATE TABLE IF NOT EXISTS live_snapshots (
        instance TEXT NOT NULL,
        stream TEXT NOT NULL,
        payload BLOB NOT NULL,
        captured_at REAL NOT NULL,
        PRIMARY KEY (instance, stream)
    ) STRICT, WITHOUT ROWID;
    PRAGMA user_version = 1;
    """
}
