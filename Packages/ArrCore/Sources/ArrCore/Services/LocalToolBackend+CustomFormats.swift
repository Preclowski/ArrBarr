import os
import Foundation
import MediaKit

// MARK: - Custom-format chat tools

extension LocalToolBackend {

    /// nil for a missing/unknown value so the caller can prompt the user.
    private func customFormatTarget(_ args: JSONValue) -> (ServiceConfig, QueueItem.Source)? {
        switch Self.stringArg(args, key: "service").lowercased() {
        case "sonarr": return (sonarr, .sonarr)
        case "radarr": return (radarr, .radarr)
        default:       return nil
        }
    }

    /// Sonarr and Radarr share the v3 custom-format / quality-profile endpoints, so an existential is enough.
    private func arrAPIClient(for source: QueueItem.Source, config: ServiceConfig) -> any ArrAPIClient {
        ServiceHandles.arr(source, config: config)
    }

    /// No `name`/`names`/`id` → list everything; otherwise describe the named ones.
    func customFormats(_ args: JSONValue) async throws -> ToolCallOutput {
        let names = Self.formatNameQueries(args)
        let id = Self.optionalIntArg(args, key: "id")
        if names.isEmpty && id == nil {
            return try await listCustomFormats(args)
        }
        return try await describeFormats(args, names: names, id: id)
    }

    /// `name` and `names` merged: models send either, sometimes both.
    nonisolated private static func formatNameQueries(_ args: JSONValue) -> [String] {
        var queries = [stringArg(args, key: "name")]
        if case .object(let dict) = args, case .array(let entries) = dict["names"] {
            queries += entries.compactMap { if case .string(let s) = $0 { s } else { nil } }
        }
        var seen = Set<String>()
        return queries
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func listCustomFormats(_ args: JSONValue) async throws -> ToolCallOutput {
        guard let (config, source) = customFormatTarget(args) else {
            return ToolCallOutput(text: "Specify which service to query: 'sonarr' or 'radarr'.")
        }
        guard config.isConfigured else {
            return ToolCallOutput(text: "\(source.displayName) is not configured.")
        }
        let formats = try await arrAPIClient(for: source, config: config).fetchCustomFormats()
        guard !formats.isEmpty else {
            return ToolCallOutput(text: "\(source.displayName) has no custom formats defined.")
        }
        let lines = formats
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { cf -> String in
                let count = cf.specifications?.count ?? 0
                let cond = count == 1 ? "1 condition" : "\(count) conditions"
                return "• [\(cf.id)] \(cf.name) — \(cond)"
            }
        let text = "\(source.displayName) custom formats (\(formats.count)):\n"
            + lines.joined(separator: "\n")
            + "\n\nCall custom_formats again with `names` (or an `id`) to see what they match and how they score."
        return ToolCallOutput(text: text)
    }

    /// Formats and profiles are read once for the whole batch.
    func describeFormats(_ args: JSONValue, names: [String], id: Int?) async throws -> ToolCallOutput {
        guard let (config, source) = customFormatTarget(args) else {
            return ToolCallOutput(text: "Specify which service to query: 'sonarr' or 'radarr'.")
        }
        guard config.isConfigured else {
            return ToolCallOutput(text: "\(source.displayName) is not configured.")
        }

        let client = arrAPIClient(for: source, config: config)
        let formats = try await client.fetchCustomFormats()

        // Match by id first (exact), else exact name, else first substring hit.
        var matched: [ArrCustomFormatDetail] = []
        var misses: [String] = []
        if let id {
            if let cf = formats.first(where: { $0.id == id }) { matched.append(cf) } else { misses.append("id \(id)") }
        }
        for query in names {
            let lower = query.lowercased()
            if let cf = formats.first(where: { $0.name.lowercased() == lower })
                ?? formats.first(where: { $0.name.lowercased().contains(lower) }) {
                if !matched.contains(where: { $0.id == cf.id }) { matched.append(cf) }
            } else {
                misses.append("named '\(query)'")
            }
        }

        var sections: [String] = []
        if !matched.isEmpty {
            let profiles = (await Logger.extras.attempt("custom format profiles") { try await client.fetchQualityProfiles() }) ?? []
            sections += matched.map { Self.describe($0, source: source, profiles: profiles) }
        }
        if !misses.isEmpty {
            let available = formats.prefix(40).map(\.name).joined(separator: ", ")
            sections.append("No custom format \(misses.joined(separator: ", ")) in \(source.displayName). "
                + "Available: \(available.isEmpty ? "(none)" : available)")
        }
        return ToolCallOutput(text: sections.joined(separator: "\n\n"))
    }

    nonisolated private static func describe(_ cf: ArrCustomFormatDetail, source: QueueItem.Source,
                                             profiles: [ArrQualityProfile]) -> String {
        var out = "\(source.displayName) custom format: \(cf.name) (id \(cf.id))\n"

        let specs = cf.specifications ?? []
        if specs.isEmpty {
            out += "\nConditions: (none defined)"
        } else {
            out += "\nConditions:"
            for spec in specs {
                out += "\n" + describeSpecification(spec)
            }
        }

        let scored: [(String, Int)] = profiles.compactMap { profile in
            guard let item = profile.formatItems?.first(where: { $0.format == cf.id }),
                  item.score != 0 else { return nil }
            return (profile.name, item.score)
        }
        if profiles.isEmpty {
            out += "\n\nScores: (couldn't read quality profiles)"
        } else if scored.isEmpty {
            out += "\n\nScores: 0 in every quality profile (no points assigned)."
        } else {
            out += "\n\nScores:"
            for (name, score) in scored.sorted(by: { $0.1 > $1.1 }) {
                out += "\n• \(name): \(score > 0 ? "+" : "")\(score)"
            }
            let zeroCount = profiles.count - scored.count
            if zeroCount > 0 {
                out += "\n• (\(zeroCount) other profile\(zeroCount == 1 ? "" : "s"): 0)"
            }
        }
        return out
    }

    nonisolated private static func describeSpecification(_ spec: ArrCustomFormatDetail.Specification) -> String {
        let label = spec.implementationName
            ?? spec.implementation.map(Self.humanizeImplementation)
            ?? "Condition"
        var flags: [String] = []
        if spec.negate == true { flags.append("NOT") }
        if spec.required == true { flags.append("required") }
        let flagPart = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"

        // Usually the field literally named "value"; else join any non-empty fields.
        let values = (spec.fields ?? []).compactMap { field -> String? in
            guard let v = field.value, let s = stringifyJSON(v), !s.isEmpty else { return nil }
            return s
        }
        let valuePart = values.isEmpty ? "" : ": \(values.joined(separator: ", "))"
        let title = spec.name ?? label
        return "• \(title) (\(label))\(flagPart)\(valuePart)"
    }

    /// For when the API omits `implementationName`.
    nonisolated private static func humanizeImplementation(_ raw: String) -> String {
        let trimmed = raw.hasSuffix("Specification")
            ? String(raw.dropLast("Specification".count))
            : raw
        var result = ""
        for ch in trimmed {
            if ch.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(ch)
        }
        return result.isEmpty ? raw : result
    }

    nonisolated private static func stringifyJSON(_ value: JSONValue) -> String? {
        switch value {
        case .null:           return nil
        case .bool(let b):    return b ? "true" : "false"
        case .number(let n):  return n == n.rounded() ? String(Int(n)) : String(n)
        case .string(let s):  return s
        case .array(let arr):
            let parts = arr.compactMap { stringifyJSON($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .object(let dict):
            let parts = dict.compactMap { k, v in stringifyJSON(v).map { "\(k)=\($0)" } }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }
}
