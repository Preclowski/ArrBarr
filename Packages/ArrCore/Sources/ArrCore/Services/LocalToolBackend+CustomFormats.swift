import Foundation

// MARK: - Custom-format chat tools
//
// `list_custom_formats` and `describe_format` let the assistant explain a
// user's TRaSH-style quality scoring setup — what each custom format
// matches and where it earns/loses points across quality profiles. Both
// are read-only (not in MCPToolWhitelist.isDestructive), so they run
// without a confirm gate. Sonarr + Radarr share the v3 `/customformat`
// and `/qualityprofile` endpoints, so one code path covers both.

extension LocalToolBackend {

    /// Resolve the `service` arg to a (config, source) pair. Returns nil
    /// for a missing/unknown value so the caller can prompt the user.
    private func customFormatTarget(_ args: JSONValue) -> (ServiceConfig, QueueItem.Source)? {
        switch Self.stringArg(args, key: "service").lowercased() {
        case "sonarr": return (sonarr, .sonarr)
        case "radarr": return (radarr, .radarr)
        default:       return nil
        }
    }

    /// Sonarr + Radarr both conform to `ArrAPIClient` and share the v3
    /// custom-format / quality-profile endpoints, so an existential is
    /// enough — `fetchCustomFormats()` / `fetchQualityProfiles()` are
    /// protocol-extension methods that work the same on either.
    private func arrAPIClient(for source: QueueItem.Source, config: ServiceConfig) -> any ArrAPIClient {
        source == .radarr ? RadarrClient(config: config) : SonarrClient(config: config)
    }

    /// Single entry point for the merged `custom_formats` tool: no
    /// `name`/`id` → list everything; either present → describe that one.
    func customFormats(_ args: JSONValue) async throws -> ToolCallOutput {
        let name = Self.stringArg(args, key: "name").trimmingCharacters(in: .whitespaces)
        let id = Self.optionalIntArg(args, key: "id")
        if name.isEmpty && id == nil {
            return try await listCustomFormats(args)
        }
        return try await describeFormat(args)
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
            + "\n\nCall custom_formats again with a `name` or `id` to see what one matches and how it scores."
        return ToolCallOutput(text: text)
    }

    func describeFormat(_ args: JSONValue) async throws -> ToolCallOutput {
        guard let (config, source) = customFormatTarget(args) else {
            return ToolCallOutput(text: "Specify which service to query: 'sonarr' or 'radarr'.")
        }
        guard config.isConfigured else {
            return ToolCallOutput(text: "\(source.displayName) is not configured.")
        }
        let nameQuery = Self.stringArg(args, key: "name").trimmingCharacters(in: .whitespaces)
        let idQuery = Self.optionalIntArg(args, key: "id")
        guard !nameQuery.isEmpty || idQuery != nil else {
            return ToolCallOutput(text: "Provide the custom format 'name' or 'id' to describe.")
        }

        let client = arrAPIClient(for: source, config: config)
        let formats = try await client.fetchCustomFormats()

        // Match by id first (exact), else exact name, else first substring hit.
        let lowerName = nameQuery.lowercased()
        let match: ArrCustomFormatDetail? = {
            if let idQuery { return formats.first { $0.id == idQuery } }
            return formats.first { $0.name.lowercased() == lowerName }
                ?? formats.first { $0.name.lowercased().contains(lowerName) }
        }()

        guard let cf = match else {
            let target = idQuery.map { "id \($0)" } ?? "named '\(nameQuery)'"
            let available = formats.prefix(40).map(\.name).joined(separator: ", ")
            return ToolCallOutput(text: "No custom format \(target) in \(source.displayName). "
                + "Available: \(available.isEmpty ? "(none)" : available)")
        }

        var out = "\(source.displayName) custom format: \(cf.name) (id \(cf.id))\n"

        // Conditions.
        let specs = cf.specifications ?? []
        if specs.isEmpty {
            out += "\nConditions: (none defined)"
        } else {
            out += "\nConditions:"
            for spec in specs {
                out += "\n" + Self.describeSpecification(spec)
            }
        }

        // Scores per quality profile.
        let profiles = (try? await client.fetchQualityProfiles()) ?? []
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
        return ToolCallOutput(text: out)
    }

    /// One readable line per specification: human label, negate/required
    /// flags, and the matched value(s).
    private static func describeSpecification(_ spec: ArrCustomFormatDetail.Specification) -> String {
        let label = spec.implementationName
            ?? spec.implementation.map(Self.humanizeImplementation)
            ?? "Condition"
        var flags: [String] = []
        if spec.negate == true { flags.append("NOT") }
        if spec.required == true { flags.append("required") }
        let flagPart = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"

        // The meaningful field is usually the one literally named "value";
        // fall back to joining any non-empty fields.
        let values = (spec.fields ?? []).compactMap { field -> String? in
            guard let v = field.value, let s = stringifyJSON(v), !s.isEmpty else { return nil }
            return s
        }
        let valuePart = values.isEmpty ? "" : ": \(values.joined(separator: ", "))"
        let title = spec.name ?? label
        return "• \(title) (\(label))\(flagPart)\(valuePart)"
    }

    /// "ReleaseTitleSpecification" → "Release Title". Best-effort prettifier
    /// for when the API omits `implementationName`.
    private static func humanizeImplementation(_ raw: String) -> String {
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

    /// Flatten a `JSONValue` field value to a compact display string.
    private static func stringifyJSON(_ value: JSONValue) -> String? {
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
