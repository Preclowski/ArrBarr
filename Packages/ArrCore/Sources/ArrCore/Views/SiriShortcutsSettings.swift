import SwiftUI
import AppIntents

/// Settings content educating the user about ArrBarr's Siri / Shortcuts
/// actions, with one-tap "Add to Siri" tips and a link into the Shortcuts
/// app. Embedded as Form sections on both platforms. Read-only actions, so
/// no per-command toggles — they're always available.
@available(iOS 16.0, macOS 13.0, *)
public struct SiriShortcutsSettingsContent: View {
    @Environment(\.openURL) private var openURL
    public init() {}

    public var body: some View {
        #if os(iOS)
        // SiriTipView is iOS-only — one-tap "Add to Siri" per action.
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
        Section {
            Button {
                if let url = URL(string: "shortcuts://") { openURL(url) }
            } label: {
                Label { Text("settings.openShortcutsApp.button", bundle: .module) } icon: { Image(systemName: "square.2.layers.3d") }
            }
        }
    }
}
