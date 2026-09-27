import SwiftUI

/// Reachable only in App Store builds (entries are `#if APPSTORE` in SettingsView).
struct ICloudSettingsView: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var coordinator = ICloudSettingsView.coordinator

    /// Cached static fallback: a computed `shared ?? fallback` would create a throwaway every render and break observation.
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
