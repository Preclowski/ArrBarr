import SwiftUI

/// Settings → MCP pane (mock).
///
/// Presents the intended Model-Context-Protocol server config — enable, bind
/// `host:port`, basic auth, and a per-tool opt-out list grouped by service.
/// Every control is wired to `ConfigStore` so the choices persist across
/// relaunches, but nothing spins up an actual server yet; this is the UI half
/// of the feature. Wiring a real transport later reads the same fields.
struct MCPSettingsPane: View {
    @EnvironmentObject var configStore: ConfigStore

    private var enabledToolCount: Int {
        ChatToolCatalog.allToolNames.count - configStore.mcpDisabledTools.count
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $configStore.mcpEnabled) { Text("Enable MCP server", bundle: .module) }
            } header: {
                Text("MCP Server", bundle: .module)
            } footer: {
                Text("Exposes ArrBarr's tools over the Model Context Protocol so an external client can drive your media stack. Not yet active — these settings are saved but no server runs.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if configStore.mcpEnabled {
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
                TextField("", text: $configStore.mcpHostPort,
                          prompt: Text(verbatim: "0.0.0.0:8080"))
                    .technicalField()
            } label: {
                Text("Listen address", bundle: .module)
            }
        } header: {
            Text("Connection", bundle: .module)
        } footer: {
            Text("host:port to bind the server to. Use 0.0.0.0 to accept connections on every network interface, or 127.0.0.1 to keep it local.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Authentication

    private var authSection: some View {
        Section {
            Toggle(isOn: $configStore.mcpRequireAuth) { Text("Require basic auth", bundle: .module) }
            if configStore.mcpRequireAuth {
                TextField(text: $configStore.mcpAuthUsername,
                          prompt: Text("Username", bundle: .module)) {
                    Text("Username", bundle: .module)
                }
                .technicalField()
                SecureField(text: $configStore.mcpAuthPassword,
                            prompt: Text("Password", bundle: .module)) {
                    Text("Password", bundle: .module)
                }
                .apiKeyField()
            }
        } header: {
            Text("Authentication", bundle: .module)
        } footer: {
            if configStore.mcpRequireAuth && (configStore.mcpAuthUsername.isEmpty || configStore.mcpAuthPassword.isEmpty) {
                Label {
                    Text("Set a username and password — auth stays off until both are filled.", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
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
                Text("Tools", bundle: .module)
                Spacer()
                Button { toggleAll() } label: {
                    Text(allToolsEnabled ? "Disable all" : "Enable all", bundle: .module)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        } footer: {
            Text(String(format: String(localized: "%1$lld of %2$lld tools exposed", bundle: .module),
                        enabledToolCount, ChatToolCatalog.allToolNames.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One tool: name + short helper on the left, the apps it drives as a row
    /// of brand icons, then the on/off switch.
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
            appIcons(tool.services)
            Toggle("", isOn: toolBinding(tool.name))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    /// Brand icons for the apps a tool supports. Caps the visible run and
    /// spills the remainder into a `+N` chip so wide-reaching tools (health
    /// touches every service) don't blow out the row.
    private static let maxVisibleIcons = 4
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
            }
        }
    }

    // MARK: - Bindings / mutations

    /// A tool is ON unless it's in the disabled set, so the stored set only
    /// ever holds the user's explicit opt-outs (default = everything exposed).
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

    /// Header "Enable all / Disable all" flips every catalog tool at once.
    private func toggleAll() {
        if allToolsEnabled {
            configStore.mcpDisabledTools = Set(ChatToolCatalog.allToolNames)
        } else {
            configStore.mcpDisabledTools = []
        }
    }
}
