import Foundation

public actor IdentityStore {
    private let database: SQLiteDatabase?
    private var edges: [MediaID: [Crosswalk]] = [:]

    public init(database: SQLiteDatabase?) {
        self.database = database
    }

    /// Pure lookup, no network. Two external ids meet one hop away, through the harvested
    /// record that carries both.
    public func known(_ id: MediaID, in namespace: IDNamespace, minimum: Crosswalk.Confidence = .inferred) async -> MediaID? {
        let edges = await lookup(id).filter { $0.confidence >= minimum }
        if let direct = Self.best(edges, in: namespace) { return direct }
        for edge in edges where edge.to.namespace.isRecord && edge.to.namespace != namespace {
            if let hit = Self.best(await lookup(edge.to).filter { $0.confidence >= minimum }, in: namespace) { return hit }
        }
        return nil
    }

    private static func best(_ edges: [Crosswalk], in namespace: IDNamespace) -> MediaID? {
        edges.filter { $0.to.namespace == namespace }.max { $0.confidence < $1.confidence }?.to
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
