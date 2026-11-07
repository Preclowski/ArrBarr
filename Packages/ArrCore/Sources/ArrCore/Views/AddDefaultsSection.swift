import SwiftUI
import MediaKit

/// The add form's pickers as an arr's Settings section. Profiles and folders are the arr's own, so they wait for it.
struct AddDefaultsSection: View {
    let source: QueueItem.Source
    let config: ServiceConfig
    @Binding var defaults: ArrAddDefaults

    @Environment(\.locale) private var locale
    @State private var choices = ArrAddChoices()
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var loadError: String?

    var body: some View {
        Section {
            if isLoading {
                ProgressView().controlSize(.small)
            } else if let loadError {
                Text(verbatim: loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                arrPicker("search.qualityProfile.button", \.qualityProfileId,
                          options: choices.qualityProfiles.map { ($0.id, $0.name) })
                if choices.metadataProfiles.count > 1 {
                    arrPicker("search.metadataProfile.button", \.metadataProfileId,
                              options: choices.metadataProfiles.map { ($0.id, $0.name) })
                }
                arrPicker("search.rootFolder.button", \.rootFolder,
                          options: choices.rootFolders.map { ($0, $0) })
            }
            if source == .sonarr {
                picker("search.seriesType.button", selection: $defaults.seriesType,
                       options: SonarrSeriesType.allCases.map { ($0, $0.displayName(locale: locale)) })
            }
            monitorPicker
                // On this row because it is always there; on a Section it could run once per row.
                // The whole config, not its fingerprint: a corrected key is usually the same length.
                .task(id: config) { await load() }
        } header: {
            Text("settings.addDefaults.header", bundle: .module)
        }
    }

    @ViewBuilder
    private var monitorPicker: some View {
        switch source {
        case .radarr, .whisparr:
            picker("search.monitor.button", selection: $defaults.movieMonitor,
                   options: RadarrMonitorMode.allCases.map { ($0, $0.displayName(locale: locale)) })
        case .sonarr:
            picker("search.monitor.button", selection: $defaults.seriesMonitor,
                   options: SonarrMonitorMode.allCases.map { ($0, $0.displayName(locale: locale)) })
        case .lidarr:
            picker("search.monitor.button", selection: $defaults.artistMonitor,
                   options: LidarrMonitorMode.allCases.map { ($0, $0.displayName(locale: locale)) })
        }
    }

    /// Shows what the form would start with, without storing it: a stale id survives until the user picks.
    @ViewBuilder
    private func arrPicker<T: Hashable>(_ label: LocalizedStringKey, _ stored: WritableKeyPath<ArrAddDefaults, T?>,
                                        options: [(T, String)]) -> some View {
        if let shown = ArrAddDefaults.pick(defaults[keyPath: stored], among: options.map(\.0)) {
            picker(label, selection: Binding(get: { shown }, set: { defaults[keyPath: stored] = $0 }), options: options)
        }
    }

    private func picker<T: Hashable>(_ label: LocalizedStringKey, selection: Binding<T>,
                                     options: [(T, String)]) -> some View {
        Picker(selection: selection) {
            ForEach(options, id: \.0) { value, name in
                Text(verbatim: name).tag(value)
            }
        } label: {
            Text(label, bundle: .module)
        }
    }

    private func load() async {
        // Settings edits the live config, so a URL being typed would otherwise fetch per keystroke.
        if hasLoaded {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
        }
        hasLoaded = true
        isLoading = true
        do {
            choices = try await ServiceHandles.search(source, config: config).fetchAddChoices()
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
