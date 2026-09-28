import SwiftUI
import AppIntents

/// Read-only actions, so no per-command toggles.
@available(iOS 16.0, macOS 13.0, *)
struct SiriShortcutsSettingsContent: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var configStore: ConfigStore
    @State private var clearingIntents = false
    @State private var clearedIntents = false
    init() {}

    var body: some View {
        #if os(iOS)
        Section {
            SiriTipView(intent: ShowDownloadQueueIntent())
            SiriTipView(intent: ShowUpcomingIntent())
            SiriTipView(intent: CheckArrHealthIntent())
        } header: {
            Text("settings.siriShortcuts.button", bundle: .module)
        } footer: {
            Text("settings.tapAddToSiri.tooltip", bundle: .module)
        }
        #else
        Section {
            Text("settings.arrbarrSActionsAre.tooltip", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("settings.siriShortcuts.button", bundle: .module)
        }
        #endif
        #if os(macOS)
        // iOS has no equivalent switch — it always opens the detail in-app.
        Section {
            Toggle(isOn: $configStore.spotlightOpensInApp) {
                Text("settings.spotlightOpensInArrbarr.button", bundle: .module)
            }
        } footer: {
            Text("settings.spotlightOpensInArrbarr.tooltip", bundle: .module)
        }
        #endif
        Section {
            Button {
                if let url = URL(string: "shortcuts://") { openURL(url) }
            } label: {
                Label { Text("settings.openShortcutsApp.button", bundle: .module) } icon: { Image(systemName: "square.2.layers.3d") }
            }
        }
        Section {
            Button {
                clearingIntents = true
                clearedIntents = false
                Task {
                    await SpotlightIndexer.clearIndex()
                    clearingIntents = false
                    clearedIntents = true
                }
            } label: {
                Label {
                    Text(clearedIntents ? "settings.intentsCacheCleared.button" : "settings.clearIntentsCache.button",
                         bundle: .module)
                } icon: {
                    Image(systemName: clearedIntents ? "checkmark.circle" : "trash")
                }
            }
            .disabled(clearingIntents)
        } footer: {
            Text("settings.clearIntentsCache.tooltip", bundle: .module)
        }
    }
}
