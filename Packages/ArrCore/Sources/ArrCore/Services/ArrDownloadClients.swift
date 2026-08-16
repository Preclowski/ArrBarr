import Foundation
import os

/// Shares the drop flow's category so one predicate covers the whole
/// "why isn't my arr in the list" path.
private let arrClientLog = Logger(category: "DownloadDrop")

/// `/downloadclient` as the arrs return it. Only the handful of members that
/// decide where a dropped file goes are modelled; the rest of the payload
/// (per-implementation settings, tags, priorities) is noise here.
private struct ArrDownloadClientDTO: Decodable {
    let id: Int
    let name: String
    let implementation: String
    let enable: Bool
    /// JSON key is `protocol` — a Swift keyword, hence the backticks.
    let `protocol`: String
    let fields: [Field]

    /// One settings field. `value` is genuinely polymorphic across
    /// implementations (string, number, bool, array), and we only ever want the
    /// string ones, so everything else decodes to nil rather than failing the
    /// whole client — a single int-valued field would otherwise cost us the
    /// entire download client, and with it the arr.
    struct Field: Decodable {
        let name: String
        let value: String?

        enum CodingKeys: String, CodingKey { case name, value }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            value = try? c.decode(String.self, forKey: .value)
        }
    }
}

public extension ArrAPIClient {
    /// The download clients this arr is configured to hand grabs to.
    ///
    /// This is the pivot the whole drop flow turns on: the user picks an arr,
    /// and the arr tells us which client to push the file into and under what
    /// category. Send the file anywhere else — or with the wrong category — and
    /// the arr will never claim it, leaving an orphan the user has to import by
    /// hand.
    ///
    /// Disabled clients are dropped: the arr won't watch them, so neither
    /// should we.
    func fetchDownloadClients() async throws -> [ArrDownloadClient] {
        let dtos: [ArrDownloadClientDTO] = try await get("/downloadclient")
        // "This arr offers nothing" and "this arr offers things we discarded"
        // are different problems with different fixes, and the add window can
        // only ever show the absence. Say which one it was.
        // `notice`, not `debug`: debug-level messages aren't persisted, so they
        // are useless for the one job this line has — telling a user (or us)
        // after the fact why their arr wasn't offered.
        arrClientLog.notice(
            "\(serviceName, privacy: .public): \(dtos.count, privacy: .public) download client(s) — \(dtos.map { "\($0.implementation)/\($0.protocol)\($0.enable ? "" : " (disabled)")" }.joined(separator: ", "), privacy: .public)"
        )
        return dtos.compactMap { dto in
            guard dto.enable else { return nil }
            guard let kind = DownloadKind(arrProtocol: dto.protocol) else { return nil }
            return ArrDownloadClient(
                id: dto.id,
                name: dto.name,
                implementation: dto.implementation,
                kind: kind,
                category: Self.category(in: dto.fields)
            )
        }
    }

    /// The category the arr tags its own grabs with. Every arr names the field
    /// after its media type — `tvCategory` (Sonarr, Whisparr v2),
    /// `movieCategory` (Radarr, Whisparr v3), `musicCategory` (Lidarr) — so it's
    /// matched by suffix rather than by an exhaustive list that a new arr would
    /// silently fall out of.
    ///
    /// `*ImportedCategory` is deliberately skipped: that's the category the arr
    /// moves a job to *after* importing, and putting a fresh download there
    /// means the arr never picks it up.
    private static func category(in fields: [ArrDownloadClientDTO.Field]) -> String? {
        for field in fields {
            let name = field.name.lowercased()
            guard name.hasSuffix("category"), !name.contains("imported") else { continue }
            if let value = field.value?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
