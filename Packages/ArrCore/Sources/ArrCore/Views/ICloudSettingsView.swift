import SwiftUI

/// Settings pane for iCloud sync: a master on/off toggle plus live status
/// (account availability, last sync time, last error) and a static summary of
/// what syncs. Reachable only in App Store builds (the sidebar entry and iOS
/// link are `#if APPSTORE`-gated in SettingsView).
struct ICloudSettingsView: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var coordinator = ICloudSettingsView.coordinator

    /// A non-optional coordinator for the view to observe. Falls back to a
    /// stopped instance when the shared one was never created (e.g. previews,
    /// non-APPSTORE), so status simply reads "Off / Never". It is a cached
    /// static (not `@StateObject`) because a computed `shared ?? fallback`
    /// would create a fresh throwaway every render when `shared` is nil,
    /// breaking observation.
    @MainActor private static var coordinator: KVSyncCoordinator = {
        KVSyncCoordinator.shared ?? KVSyncCoordinator(
            defaults: WidgetDataStore.groupDefaults() ?? .standard,
            kv: NSUbiquitousKeyValueStore.default,
            reload: {})
    }()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $config.iCloudSyncEnabled) {
                    Text("settings.syncWithIcloud.button", bundle: .module)
                }
            } footer: {
                Text("settings.keepYourServersPreferences.tooltip", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if config.iCloudSyncEnabled {
                statusSection
            }
            whatSyncsSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            if !coordinator.accountAvailable {
                Label {
                    Text("settings.signInToIcloud.tooltip", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent {
                if let date = coordinator.lastSyncDate {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("settings.never.button", bundle: .module)
                }
            } label: {
                Text("settings.lastSync.button", bundle: .module)
            }
            if let error = coordinator.lastError {
                Label {
                    Text(verbatim: error)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                .foregroundStyle(.red)
            }
        } header: {
            Text("settings.status.button", bundle: .module)
        }
    }

    private var whatSyncsSection: some View {
        Section {
            row("server.rack", "Server configurations")
            row("key.fill", "Passwords & API keys (iCloud Keychain)")
            row("bell.badge", "Notification settings")
            row("sparkles", "Assistant settings")
            row("rectangle.3.group", "Layout & visibility preferences")
        } header: {
            Text("settings.whatSyncs.button", bundle: .module)
        } footer: {
            Text("settings.deviceSpecificSettingsRefresh.tooltip", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ symbol: String, _ key: LocalizedStringKey) -> some View {
        Label {
            Text(key, bundle: .module)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}
