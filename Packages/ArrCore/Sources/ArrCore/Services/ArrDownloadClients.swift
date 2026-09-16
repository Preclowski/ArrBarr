import Foundation
import MediaKit
import os

private let arrClientLog = Logger(category: "DownloadDrop")

public extension ArrAPIClient {
    /// The arr's enabled download clients with the category it hands each one; drops go to the matching client.
    func fetchDownloadClients() async throws -> [ArrCore.ArrDownloadClient] {
        let rows = try await read([MediaKit.ArrDownloadClient].self, policy: .mustRevalidate) { $0.downloadClients() }
        arrClientLog.notice(
            "\(serviceName, privacy: .public): \(rows.count, privacy: .public) download client(s) — \(rows.map { "\($0.implementation ?? "?")/\($0.protocol ?? "?")\($0.enable == true ? "" : " (disabled)")" }.joined(separator: ", "), privacy: .public)"
        )
        return rows.compactMap { row in
            guard row.enable == true, let id = row.id, let kind = DownloadKind(arrProtocol: row.protocol ?? "") else { return nil }
            return ArrCore.ArrDownloadClient(id: id, name: row.name ?? "", implementation: row.implementation ?? "", kind: kind, category: Self.category(in: row.fields ?? []))
        }
    }

    private static func category(in fields: [MediaKit.ArrDownloadClient.Field]) -> String? {
        for field in fields {
            let name = (field.name ?? "").lowercased()
            guard name.hasSuffix("category"), !name.contains("imported") else { continue }
            if let value = field.value?.stringValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value }
        }
        return nil
    }
}
