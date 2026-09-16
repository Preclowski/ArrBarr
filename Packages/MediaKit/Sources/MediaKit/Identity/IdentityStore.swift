import Foundation

public actor IdentityStore {
    private let database: SQLiteDatabase?
    private let clock: any MediaClock
    private var edges: [MediaID: [Crosswalk]] = [:]

    public init(database: SQLiteDatabase?, clock: any MediaClock) {
        self.database = database; self.clock = clock
    }

    /// Pure lookup, no network.
    public func known(_ id: MediaID, in namespace: IDNamespace, minimum: Crosswalk.Confidence = .inferred) async -> MediaID? {
        await lookup(id).filter { $0.to.namespace == namespace && $0.confidence >= minimum }.max { $0.confidence < $1.confidence }?.to
    }

    public func identity(for id: MediaID, kind: MediaKind) async -> MediaIdentity {
        let ids = Set(await lookup(id).filter { $0.kind == kind }.map(\.to)).union([id])
        return MediaIdentity(kind: kind, ids: ids)
    }

    /// Upsert; higher confidence wins; both directions.
    public func record(_ new: [Crosswalk]) async {
        guard !new.isEmpty else { return }
        for edge in new.flatMap({ [$0, $0.reversed] }) {
            var list = edges[edge.from] ?? []
            if let i = list.firstIndex(where: { $0.to.namespace == edge.to.namespace && $0.kind == edge.kind }) {
                if edge.confidence >= list[i].confidence { list[i] = edge }
            } else {
                list.append(edge)
            }
            edges[edge.from] = list
        }
        try? await database?.putCrosswalk(new)
    }

    public func forget(instance: InstanceID) async {
        let namespaces: Set<IDNamespace> = [.arr(instance), .mediaServer(instance)]
        edges = edges.compactMapValues { list in
            let kept = list.filter { !namespaces.contains($0.to.namespace) }
            return kept.isEmpty ? nil : kept
        }
        for key in edges.keys where namespaces.contains(key.namespace) { edges.removeValue(forKey: key) }
        try? await database?.forgetCrosswalk(instance: instance)
    }

    private func lookup(_ id: MediaID) async -> [Crosswalk] {
        if let cached = edges[id] { return cached }
        let loaded = (try? await database?.crosswalk(from: id, kind: nil)) ?? []
        edges[id] = loaded
        return loaded
    }
}
