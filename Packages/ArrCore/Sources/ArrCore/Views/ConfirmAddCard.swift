import SwiftUI

// MARK: - ConfirmAddCard

/// Rich confirm card shown when the LLM calls a destructive add tool
/// (`sonarr_add_series` / `radarr_add_movie`). Fetches the poster, quality
/// profiles, and root folders in parallel so the user can review and adjust
/// before confirming.
public struct ConfirmAddCard: View {
    let call: ToolCall
    let sonarr: ServiceConfig
    let radarr: ServiceConfig
    let onConfirm: (JSONValue) -> Void
    let onCancel: () -> Void

    // MARK: - Derived configuration

    private var isSonarr: Bool { call.name.hasPrefix("sonarr_") }
    private var config: ServiceConfig { isSonarr ? sonarr : radarr }
    private var source: QueueItem.Source { isSonarr ? .sonarr : .radarr }
    private var idKey: String { isSonarr ? "tvdbId" : "tmdbId" }

    private var lookupQuery: String {
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

    enum Phase {
        case loading
        case loaded(result: SearchResult, profiles: [QualityProfile], folders: [RootFolder])
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
                case .loaded(let result, let profiles, let folders):
                    cardView(result: result, profiles: profiles, folders: folders)
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

    private func cardView(result: SearchResult, profiles: [QualityProfile], folders: [RootFolder]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // — Header: poster + metadata
            HStack(alignment: .top, spacing: 10) {
                RemotePoster(
                    url: result.posterURL,
                    apiKey: config.apiKey,
                    size: CGSize(width: 60, height: 90),
                    cornerRadius: 6
                )
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

            // — Single-row controls: profile · folder · cancel · confirm
            HStack(spacing: 8) {
                if profiles.count > 1 {
                    Picker("", selection: Binding(get: { selectedProfileId }, set: { selectedProfileId = $0 })) {
                        ForEach(profiles, id: \.id) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
                if folders.count > 1 {
                    Picker("", selection: Binding(get: { selectedFolderPath }, set: { selectedFolderPath = $0 })) {
                        ForEach(folders, id: \.path) { f in
                            Text(Self.shortenPath(f.path)).tag(f.path)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
                Spacer(minLength: 0)
                Button(Self.locStr("Cancel"), action: onCancel)
                    .controlSize(.small)
                Button(Self.locStr("Confirm")) {
                    onConfirm(mergedArgs(profiles: profiles, folders: folders))
                }
                .controlSize(.small)
                #if os(macOS)
                .keyboardShortcut(.defaultAction)
                #endif
            }
        }
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

    private func mergedArgs(profiles: [QualityProfile], folders: [RootFolder]) -> JSONValue {
        var dict: [String: JSONValue]
        if case .object(let d) = call.arguments {
            dict = d
        } else {
            dict = [:]
        }
        dict["qualityProfileId"] = .number(Double(selectedProfileId))
        dict["rootFolderPath"] = .string(selectedFolderPath)
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
            let (results, profiles, folders) = try await (resultsTask, profilesTask, foldersTask)

            let idVal = argInt(idKey)
            let picked: SearchResult?
            if idVal != 0 {
                picked = results.first(where: { $0.id == idVal }) ?? results.first
            } else {
                picked = results.first
            }
            guard let pick = picked else {
                phase = .failed("No results found.")
                return
            }
            // Default selections
            if let first = profiles.first { selectedProfileId = first.id }
            if let first = folders.first { selectedFolderPath = first.path }
            phase = .loaded(result: pick, profiles: profiles, folders: folders)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
