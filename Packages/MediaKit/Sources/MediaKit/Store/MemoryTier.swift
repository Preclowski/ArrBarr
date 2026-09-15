import Foundation

/// LRU by bytes; the only home of `.volatile` rows.
struct MemoryTier {
    struct Row {
        let entry: StoredEntry
        var lastUsed: Date
    }

    private(set) var rows: [ResourceKey: Row] = [:]
    private(set) var bytes = 0
    let budget: Int

    init(budget: Int) { self.budget = budget }

    mutating func get(_ key: ResourceKey, fingerprint: Fingerprint, now: Date) -> StoredEntry? {
        guard var row = rows[key], row.entry.fingerprint == fingerprint else { return nil }
        row.lastUsed = now
        rows[key] = row
        return row.entry
    }

    mutating func put(_ entry: StoredEntry, now: Date) {
        if let old = rows[entry.key] { bytes -= old.entry.payload.count }
        rows[entry.key] = Row(entry: entry, lastUsed: now)
        bytes += entry.payload.count
        while bytes > budget, let victim = rows.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            bytes -= victim.value.entry.payload.count
            rows.removeValue(forKey: victim.key)
        }
    }

    mutating func markStale(tags: Set<InvalidationTag>, at date: Date) {
        for (key, var row) in rows where !row.entry.tags.isDisjoint(with: tags) {
            row = Row(entry: stale(row.entry, at: date), lastUsed: row.lastUsed)
            rows[key] = row
        }
    }

    mutating func markStale(instance: InstanceID, at date: Date) {
        for (key, row) in rows where key.instance == instance {
            rows[key] = Row(entry: stale(row.entry, at: date), lastUsed: row.lastUsed)
        }
    }

    mutating func remove(where predicate: (StoredEntry) -> Bool) {
        for (key, row) in rows where predicate(row.entry) {
            bytes -= row.entry.payload.count
            rows.removeValue(forKey: key)
        }
    }

    mutating func removeAll() { rows = [:]; bytes = 0 }

    private func stale(_ entry: StoredEntry, at date: Date) -> StoredEntry {
        var copy = entry
        copy.staleAt = min(copy.staleAt, date)
        return copy
    }
}
