import Foundation
import Network

public struct DiscoveredServer: Sendable, Hashable {
    public enum Source: String, Sendable { case bonjour, udpBeacon }
    public let kind: InstanceKind
    public let name: String
    public let endpoint: URL
    public let identifier: String?
    public let source: Source
}

/// Plex over Bonjour, Jellyfin/Emby over the UDP 7359 beacon (macOS only). Results are Settings hints; nothing is written.
public actor Discovery {
    private let log: any LogSink
    public init(log: any LogSink) { self.log = log }

    public func scan(for kinds: Set<InstanceKind>, timeout: Duration = .seconds(4)) async -> [DiscoveredServer] {
        var found = Set<DiscoveredServer>()
        await withTaskGroup(of: [DiscoveredServer].self) { group in
            if kinds.contains(.plex) { group.addTask { await Self.bonjour(timeout: timeout) } }
            #if os(macOS)
            if !kinds.isDisjoint(with: [.jellyfin, .emby]) { group.addTask { await Self.beacon(timeout: timeout) } }
            #endif
            for await batch in group { found.formUnion(batch) }
        }
        log.log(.debug, category: "Discovery", "found \(found.count) server(s)")
        return found.sorted { $0.name < $1.name }
    }

    private static func bonjour(timeout: Duration) async -> [DiscoveredServer] {
        let browser = NetworkBrowser(for: .bonjour("_plexmediasvr._tcp", domain: nil, includeTxtRecord: true))
        let results = Results()
        let run = Task {
            try await browser.run { endpoints in
                for endpoint in endpoints {
                    let txt = endpoint.txtRecord.dictionary
                    if let server = parseBonjour(name: endpoint.name, txt: txt, host: txt["host"] ?? endpoint.name, port: Int(txt["port"] ?? "") ?? 32400) {
                        results.add(server)
                    }
                }
            }
        }
        try? await Task.sleep(for: timeout)
        run.cancel()
        return results.all
    }

    private static func beacon(timeout: Duration) async -> [DiscoveredServer] {
        let results = Results()
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(host: "255.255.255.255", port: 7359, using: parameters)
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            connection.send(content: Data("who is JellyfinServer?".utf8), completion: .contentProcessed { _ in })
            // One beacon reply per server; a second receive picks up late answers.
            for _ in 0..<8 {
                connection.receiveMessage { data, _, _, _ in
                    if let data, let server = parseBeacon(data, from: "") { results.add(server) }
                }
            }
        }
        connection.start(queue: .global(qos: .utility))
        try? await Task.sleep(for: timeout)
        connection.cancel()
        return results.all
    }

    public nonisolated static func parseBonjour(name: String, txt: [String: String], host: String, port: Int) -> DiscoveredServer? {
        guard !host.isEmpty, port > 0, let url = URL(string: "http://\(host):\(port)") else { return nil }
        return DiscoveredServer(kind: .plex, name: txt["name"] ?? name, endpoint: url, identifier: txt["machineIdentifier"], source: .bonjour)
    }

    /// `{"Address":"http://host:8096","Id":"…","Name":"…","EndpointAddress":null}`; Emby answers the same shape.
    public nonisolated static func parseBeacon(_ payload: Data, from host: String) -> DiscoveredServer? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let address = json["Address"] as? String, let url = URL(string: address), url.host != nil else { return nil }
        let name = json["Name"] as? String ?? host
        let kind: InstanceKind = name.localizedCaseInsensitiveContains("emby") || address.contains("8096") == false && name.isEmpty ? .emby : .jellyfin
        return DiscoveredServer(kind: kind, name: name, endpoint: url, identifier: json["Id"] as? String, source: .udpBeacon)
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var set = Set<DiscoveredServer>()
        func add(_ s: DiscoveredServer) { lock.withLock { _ = set.insert(s) } }
        var all: [DiscoveredServer] { lock.withLock { Array(set) } }
    }
}
