import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// On macOS `MCPServerController` starts/stops the server from these settings
/// and reports into `MCPServerStatusModel`.
struct MCPSettingsPane: View {
    @Environment(ConfigStore.self) var configStore

    private var enabledToolCount: Int {
        ChatToolCatalog.allToolNames.count - configStore.mcpDisabledTools.count
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Bindable(configStore).mcpEnabled) { Text("settings.enableMcpServer.button", bundle: .module) }
            } header: {
                Text("settings.mcpServer.button", bundle: .module)
            } footer: {
                Text("chat.exposesArrbarrSTools.tooltip", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if configStore.mcpEnabled {
                statusSection
                connectionSection
                authSection
                toolsSections
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            LabeledContent {
                TextField("", text: Bindable(configStore).mcpHostPort,
                          prompt: Text(verbatim: "0.0.0.0:8080"))
                    .technicalField()
            } label: {
                Text("settings.listenAddress.button", bundle: .module)
            }
        } header: {
            Text("settings.connection.button", bundle: .module)
        } footer: {
            Text("settings.hostPortToBind.tooltip", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status

    @ViewBuilder private var statusRow: some View {
        switch MCPServerStatusModel.shared.status {
        case .stopped:
            Label { Text("settings.stopped.button", bundle: .module) }
            icon: { Circle().fill(.gray).frame(width: 8, height: 8) }
        case .running(let url):
            LabeledContent {
                HStack(spacing: 8) {
                    Text(verbatim: url).font(.callout.monospaced()).textSelection(.enabled)
                    Button { copy(url) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Copy server URL", bundle: .module))
                }
            } label: {
                Label { Text("settings.running.button", bundle: .module) }
                icon: { Circle().fill(.green).frame(width: 8, height: 8) }
            }
        case .failed(let message):
            Label { Text(verbatim: message) }
            icon: { Circle().fill(.red).frame(width: 8, height: 8) }
                .foregroundStyle(.red)
        }
    }

    private var statusSection: some View {
        Section { statusRow } header: { Text("settings.status.button", bundle: .module) }
    }

    // MARK: - Authentication

    private var authSection: some View {
        Section {
            Toggle(isOn: Bindable(configStore).mcpRequireAuth) { Text("settings.requireBearerToken.button", bundle: .module) }
            if configStore.mcpRequireAuth {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(verbatim: configStore.mcpAuthToken.isEmpty ? "—" : configStore.mcpAuthToken)
                            .font(.callout.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button { copy(configStore.mcpAuthToken) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .disabled(configStore.mcpAuthToken.isEmpty)
                            .accessibilityLabel(Text("Copy token", bundle: .module))
                        Button { configStore.mcpAuthToken = MCPTokenStore.generate() } label: {
                            Text(configStore.mcpAuthToken.isEmpty ? "common.generate.button" : "common.regenerate.button", bundle: .module)
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                } label: {
                    Text("settings.token.button", bundle: .module)
                }
            }
        } header: {
            Text("settings.authentication.button", bundle: .module)
        } footer: {
            if configStore.mcpRequireAuth && configStore.mcpAuthToken.isEmpty {
                warning("settings.mcpGenerateTokenFirst.warning")
            } else if !configStore.mcpRequireAuth && !configStore.mcpHostPort.hasPrefix("127.0.0.1") {
                warning("settings.mcpNoAuthOnNetwork.warning")
            }
        }
    }

    private func warning(_ key: LocalizedStringKey) -> some View {
        Label { Text(key, bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .font(.caption).foregroundStyle(.orange)
    }

    private func copy(_ s: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }

    // MARK: - Tools

    @ViewBuilder
    private var toolsSections: some View {
        Section {
            ForEach(ChatToolCatalog.toolDirectory) { tool in
                toolRow(tool)
            }
        } header: {
            HStack(spacing: 6) {
                Text("settings.tools.button", bundle: .module)
                Spacer()
                Button { toggleAll() } label: {
                    Text(allToolsEnabled ? "Disable all" : "Enable all", bundle: .module)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: AppLocalized.string("settings.toolsExposedCount.label",
                                                         locale: configStore.currentLocale),
                            enabledToolCount, ChatToolCatalog.allToolNames.count))
                Text("settings.toolsAreOnlyRegistered.tooltip", bundle: .module)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func toolRow(_ tool: ChatToolCatalog.MCPToolInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: tool.name)
                    .font(.callout.monospaced())
                Text(LocalizedStringKey(tool.summary), bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            toolIcons(tool)
            // `.labelsHidden()` also strips the accessibility name.
            Toggle("", isOn: toolBinding(tool.name))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text(verbatim: tool.name))
                .accessibilityHint(Text(LocalizedStringKey(tool.summary), bundle: .module))
        }
        .padding(.vertical, 2)
    }

    /// Wide tools (health touches every service) spill into a `+N` chip.
    private static let maxVisibleIcons = 4

    /// SF Symbol for tools outside the brand roster (the media server has no mark).
    @ViewBuilder
    private func toolIcons(_ tool: ChatToolCatalog.MCPToolInfo) -> some View {
        if let systemImage = tool.systemImage, tool.services.isEmpty {
            Image(systemName: systemImage)
                .scaledFont(size: 13)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("settings.mediaServer.label", bundle: .module))
        } else {
            appIcons(tool.services)
        }
    }

    @ViewBuilder
    private func appIcons(_ services: [ServiceKind]) -> some View {
        let visible = services.prefix(Self.maxVisibleIcons)
        let overflow = services.count - visible.count
        HStack(spacing: 3) {
            ForEach(Array(visible), id: \.self) { kind in
                ServiceIcon(kind: kind, size: 15)
            }
            if overflow > 0 {
                Text(verbatim: "+\(overflow)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .help(Text(verbatim: services.dropFirst(Self.maxVisibleIcons)
                        .map(\.displayName).joined(separator: ", ")))
            }
        }
        // One element that names the apps instead of a strip of marks and "+2".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: services.map(\.displayName).joined(separator: ", ")))
    }

    // MARK: - Bindings / mutations

    /// The stored set holds only explicit opt-outs; default is everything exposed.
    private func toolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { !configStore.mcpDisabledTools.contains(name) },
            set: { on in
                if on { configStore.mcpDisabledTools.remove(name) }
                else { configStore.mcpDisabledTools.insert(name) }
            }
        )
    }

    private var allToolsEnabled: Bool {
        configStore.mcpDisabledTools.isEmpty
    }

    private func toggleAll() {
        if allToolsEnabled {
            configStore.mcpDisabledTools = Set(ChatToolCatalog.allToolNames)
        } else {
            configStore.mcpDisabledTools = []
        }
    }
}
