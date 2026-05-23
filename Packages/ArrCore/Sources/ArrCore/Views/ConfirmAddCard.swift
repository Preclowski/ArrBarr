import SwiftUI

// MARK: - ConfirmAddCard

/// Rich confirm card shown when the LLM calls any destructive tool
/// flagged by `MCPToolWhitelist.isDestructive` (`_add_` / `_delete_`
/// prefixes). Fetches the poster, quality profiles, root folders (and
/// metadata profiles for Lidarr) in parallel so the user can review and
/// adjust before confirming.
///
/// As of the "drop *_add_* tools" change, no currently-shipped tool is
/// destructive — the card is effectively unreachable. It stays as
/// infrastructure: the moment a destructive tool ships again (batch add,
/// queue delete, etc.) the confirm flow lights back up without a rebuild.
public struct ConfirmAddCard: View {
    let call: ToolCall
    let sonarr: ServiceConfig
    let radarr: ServiceConfig
    let lidarr: ServiceConfig
    var whisparr: ServiceConfig = .empty
    var blurWhisparrPosters: Bool = true
    let onConfirm: (JSONValue) -> Void
    let onCancel: () -> Void

    // MARK: - Derived configuration

    private var isSonarr: Bool { call.name.hasPrefix("sonarr_") }
    private var isLidarr: Bool { call.name.hasPrefix("lidarr_") }
    private var isWhisparr: Bool { call.name.hasPrefix("whisparr_") }
    private var config: ServiceConfig {
        if isSonarr { return sonarr }
        if isLidarr { return lidarr }
        if isWhisparr { return whisparr }
        return radarr
    }
    private var source: QueueItem.Source {
        if isSonarr { return .sonarr }
        if isLidarr { return .lidarr }
        if isWhisparr { return .whisparr }
        return .radarr
    }
    private var idKey: String { isSonarr ? "tvdbId" : "tmdbId" }

    private var lookupQuery: String {
        if isLidarr {
            let name = argString("artistName")
            return name.isEmpty ? argString("foreignArtistId") : name
        }
        if isWhisparr {
            let foreignId = argString("foreignId")
            return foreignId.isEmpty ? argString("title") : foreignId
        }
        let id = argInt(idKey)
        if id != 0 {
            return isSonarr ? "tvdb:\(id)" : "tmdb:\(id)"
        }
        return argString("title")
    }

    // MARK: - State

    @State private var phase: Phase = .loading
    @State private var selectedProfileId: Int = 0
    @State private var selectedFolderPath: String = ""
    @State private var selectedMetadataProfileId: Int = 0
    @State private var posterRevealed = false

    private var effectivelyBlurred: Bool { isWhisparr && blurWhisparrPosters && !posterRevealed }

    enum Phase {
        case loading
        case loaded(result: SearchResult, profiles: [QualityProfile], folders: [RootFolder], metadataProfiles: [MetadataProfile])
        case failed(String)
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                switch phase {
                case .loading:
                    loadingView
                case .loaded(let result, let profiles, let folders, let metadataProfiles):
                    cardView(result: result, profiles: profiles, folders: folders, metadataProfiles: metadataProfiles)
                case .failed(let msg):
                    failedView(msg)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.06))
        }
        .task(id: call.id ?? call.name) {
            await fetchData()
        }
    }

    // MARK: - Sub-views

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading…", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(Self.locStr("Cancel"), action: onCancel).controlSize(.small)
        }
    }

    private func failedView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Couldn't load metadata", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(Self.locStr("Cancel"), action: onCancel).controlSize(.small)
            Button(Self.locStr("Confirm")) {
                onConfirm(call.arguments)
            }
            .controlSize(.small)
        }
    }

    private func cardView(result: SearchResult, profiles: [QualityProfile], folders: [RootFolder], metadataProfiles: [MetadataProfile]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // — Banner header so the user immediately knows what this card is.
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text("Confirm download", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer(minLength: 0)
            }

            // — Header: poster + metadata
            HStack(alignment: .top, spacing: 10) {
                RemotePoster(
                    url: result.posterURL,
                    apiKey: config.apiKey,
                    size: CGSize(width: 60, height: 90),
                    cornerRadius: 6
                )
                .blur(radius: effectivelyBlurred ? 14 : 0)
                .onTapGesture { if isWhisparr && blurWhisparrPosters { posterRevealed.toggle() } }
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let year = result.year {
                            Text(String(year))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        if let rating = result.rating {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if let overview = result.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }

            // — Settings: labeled formPicker rows matching SearchAddPanel.
            //   Always rendered even with a single option, so the user can
            //   see what they're committing to before clicking Confirm.
            VStack(spacing: 4) {
                formPicker(
                    label: Self.locStr("Quality Profile"),
                    selection: Binding(get: { selectedProfileId }, set: { selectedProfileId = $0 }),
                    options: profiles.map { ($0.id, $0.name) }
                )
                if isLidarr {
                    formPicker(
                        label: Self.locStr("Metadata Profile"),
                        selection: Binding(get: { selectedMetadataProfileId }, set: { selectedMetadataProfileId = $0 }),
                        options: metadataProfiles.map { ($0.id, $0.name) }
                    )
                }
                formPicker(
                    label: Self.locStr("Root Folder"),
                    selection: Binding(get: { selectedFolderPath }, set: { selectedFolderPath = $0 }),
                    options: folders.map { ($0.path, Self.shortenPath($0.path)) }
                )
            }

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(Self.locStr("Cancel"), action: onCancel)
                    .controlSize(.small)
                Button(Self.locStr("Confirm")) {
                    onConfirm(mergedArgs(profiles: profiles, folders: folders, metadataProfiles: metadataProfiles))
                }
                .controlSize(.small)
                #if os(macOS)
                .keyboardShortcut(.defaultAction)
                #endif
            }
        }
    }

    /// Same shape as `SearchAddPanel.formPicker` — labeled row with a Menu
    /// chevron on the right. Renders even with a single option so the user
    /// can see the chosen profile/folder, not just trust an invisible default.
    private func formPicker<T: Hashable>(label: String, selection: Binding<T>,
                                         options: [(T, String)]) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(options, id: \.0) { val, name in
                    Button(name) { selection.wrappedValue = val }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(options.first(where: { $0.0 == selection.wrappedValue })?.1
                         ?? options.first?.1 ?? "—")
                        .font(.system(size: 11))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Display only the trailing path component so the chip stays narrow.
    /// e.g. "/data/media/Movies" → "Movies"
    private static func shortenPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }

    // MARK: - Helpers

    private static func locStr(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle.module, comment: "")
    }

    private func argInt(_ key: String) -> Int {
        guard case .object(let dict) = call.arguments, let v = dict[key] else { return 0 }
        switch v {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s) ?? 0
        default: return 0
        }
    }

    private func argString(_ key: String) -> String {
        guard case .object(let dict) = call.arguments,
              case .string(let s) = dict[key] else { return "" }
        return s
    }

    private func mergedArgs(profiles: [QualityProfile], folders: [RootFolder], metadataProfiles: [MetadataProfile]) -> JSONValue {
        var dict: [String: JSONValue]
        if case .object(let d) = call.arguments {
            dict = d
        } else {
            dict = [:]
        }
        dict["qualityProfileId"] = .number(Double(selectedProfileId))
        dict["rootFolderPath"] = .string(selectedFolderPath)
        if isLidarr {
            dict["metadataProfileId"] = .number(Double(selectedMetadataProfileId))
        }
        return .object(dict)
    }

    // MARK: - Data fetching

    private func fetchData() async {
        guard config.isConfigured, !lookupQuery.isEmpty else {
            phase = .failed("Service not configured or missing ID/title.")
            return
        }
        let client = SearchClient(config: config, source: source)
        do {
            async let resultsTask = client.lookup(query: lookupQuery)
            async let profilesTask = client.fetchQualityProfiles()
            async let foldersTask = client.fetchRootFolders()
            async let metaProfilesTask: [MetadataProfile] = isLidarr ? client.fetchMetadataProfiles() : []
            let (results, profiles, folders, metadataProfiles) = try await (resultsTask, profilesTask, foldersTask, metaProfilesTask)

            let picked: SearchResult?
            if isLidarr {
                // For Lidarr, match by foreignArtistId if available
                let targetForeignId = argString("foreignArtistId")
                if !targetForeignId.isEmpty {
                    picked = results.first(where: { $0.foreignId == targetForeignId }) ?? results.first
                } else {
                    picked = results.first
                }
            } else if isWhisparr {
                // For Whisparr, match by foreignId if available
                let targetForeignId = argString("foreignId")
                if !targetForeignId.isEmpty {
                    picked = results.first(where: { $0.foreignId == targetForeignId }) ?? results.first
                } else {
                    picked = results.first
                }
            } else {
                let idVal = argInt(idKey)
                if idVal != 0 {
                    picked = results.first(where: { $0.id == idVal }) ?? results.first
                } else {
                    picked = results.first
                }
            }
            guard let pick = picked else {
                phase = .failed("No results found.")
                return
            }
            // Default selections
            if let first = profiles.first { selectedProfileId = first.id }
            if let first = folders.first { selectedFolderPath = first.path }
            if let first = metadataProfiles.first { selectedMetadataProfileId = first.id }
            phase = .loaded(result: pick, profiles: profiles, folders: folders, metadataProfiles: metadataProfiles)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
