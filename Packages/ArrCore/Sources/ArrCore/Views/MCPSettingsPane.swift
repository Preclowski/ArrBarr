import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Settings → MCP pane.
///
/// Presents the MCP server config — enable, bind `host:port`, bearer-token auth,
/// live status, and a per-tool opt-out list grouped by service. Controls are
/// wired to `ConfigStore`; on macOS the app's `MCPServerController` starts/stops
/// the real server in response and pushes status back into `mcpServerStatus`.
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
                Text("Exposes ArrBarr's tools over the Model Context Protocol so an external client (e.g. Claude Desktop) can drive your media stack. This is separate from the built-in AI assistant — changing these settings does not affect the in-app chat.", bundle: .module)
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

    // MARK: - Status

    @ViewBuilder private var statusRow: some View {
        switch configStore.mcpServerStatus {
        case .stopped:
            Label { Text("Stopped", bundle: .module) }
            icon: { Circle().fill(.gray).frame(width: 8, height: 8) }
        case .running(let url):
            LabeledContent {
                HStack(spacing: 8) {
                    Text(verbatim: url).font(.callout.monospaced()).textSelection(.enabled)
                    Button { copy(url) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                }
            } label: {
                Label { Text("Running", bundle: .module) }
                icon: { Circle().fill(.green).frame(width: 8, height: 8) }
            }
        case .failed(let message):
            Label { Text(verbatim: message) }
            icon: { Circle().fill(.red).frame(width: 8, height: 8) }
                .foregroundStyle(.red)
        }
    }

    private var statusSection: some View {
        Section { statusRow } header: { Text("Status", bundle: .module) }
    }

    // MARK: - Authentication

    private var authSection: some View {
        Section {
            Toggle(isOn: $configStore.mcpRequireAuth) { Text("Require bearer token", bundle: .module) }
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
                        Button { configStore.mcpAuthToken = MCPTokenStore.generate() } label: {
                            Text(configStore.mcpAuthToken.isEmpty ? "Generate" : "Regenerate", bundle: .module)
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                } label: {
                    Text("Token", bundle: .module)
                }
            }
        } header: {
            Text("Authentication", bundle: .module)
        } footer: {
            if configStore.mcpRequireAuth && configStore.mcpAuthToken.isEmpty {
                warning("Generate a token — auth stays off until one is set.")
            } else if !configStore.mcpRequireAuth && !configStore.mcpHostPort.hasPrefix("127.0.0.1") {
                warning("Exposed on the network without authentication. Enable a bearer token.")
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
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: String(localized: "%1$lld of %2$lld tools exposed", bundle: .module),
                            enabledToolCount, ChatToolCatalog.allToolNames.count))
                Text("Tools are only registered for services you have configured — with no Sonarr/Radarr set up, the server exposes none.", bundle: .module)
            }
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
                    // Hovering "+N" lists the apps that didn't fit.
                    .help(Text(verbatim: services.dropFirst(Self.maxVisibleIcons)
                        .map(\.displayName).joined(separator: ", ")))
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
