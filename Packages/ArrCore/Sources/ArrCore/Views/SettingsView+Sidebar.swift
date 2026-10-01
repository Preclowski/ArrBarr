import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

#if os(macOS)
extension SettingsView {
    // MARK: - macOS sidebar layout (System Settings style)

    /// Window-vibrant material so the custom sidebar matches a native one.
    private struct SidebarVibrancy: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let v = NSVisualEffectView()
            v.material = .sidebar
            v.blendingMode = .behindWindow
            v.state = .followsWindowActiveState
            return v
        }
        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }


    var macSidebarLayout: some View {
        // Hand-built columns: NavigationSplitView on macOS 26 insets the sidebar as a
        // floating glass card, stranding the traffic lights off it.
        HStack(spacing: 0) {
            sidebarColumn
                .frame(width: 232)
                .background(SidebarVibrancy().ignoresSafeArea())
            Divider()
                .ignoresSafeArea()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.all)
        .onChange(of: macSelection) { _, newValue in
            recordHistory(newValue)
        }
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            // Clears the traffic lights.
            Color.clear.frame(height: 40)
            sidebarSearchField
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            List(selection: sidebarSelectionBinding) {
                if macSearch.isEmpty {
                    structuredSidebar
                } else {
                    ForEach(filteredSidebarEntries) { entry in sidebarEntryRow(entry) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailTopBar
            detailPane(for: macSelection)
        }
    }

    private var detailTopBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                // Icon-only buttons need explicit labels for VoiceOver.
                Button { goBack() } label: {
                    Image(systemName: "chevron.backward")
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(!canGoBack)
                .help(Text("settings.back.button", bundle: .module))
                .accessibilityLabel(Text("settings.back.button", bundle: .module))
                Divider().frame(height: 15)
                Button { goForward() } label: {
                    Image(systemName: "chevron.forward")
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(!canGoForward)
                .help(Text("settings.forward.button", bundle: .module))
                .accessibilityLabel(Text("settings.forward.button", bundle: .module))
            }
            .buttonStyle(.borderless)
            .font(.body.weight(.medium))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )

            navTitle(for: macSelection)
                .font(.title2.weight(.bold))

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    /// Maps an active service page back to its hub so the hub row stays highlighted.
    private var sidebarSelectionBinding: Binding<SettingsSection?> {
        Binding(
            get: { sidebarParent(of: macSelection) },
            set: { if let new = $0 { macSelection = new } }
        )
    }

    private func sidebarParent(of section: SettingsSection) -> SettingsSection {
        if case .service(let kind) = section {
            return downloadClientSpecs.contains { $0.kind == kind } ? .downloadClients : .mediaManagers
        }
        if case .prowlarr = section { return .mediaManagers }
        return section
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .scaledFont(size: 13)
                .accessibilityHidden(true)
            TextField(text: $macSearch) { Text("search.search.button", bundle: .module) }
                .textFieldStyle(.plain)
                .scaledFont(size: 13)
            if !macSearch.isEmpty {
                Button { macSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search", bundle: .module))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.7))
        )
    }

    @ViewBuilder
    private var structuredSidebar: some View {
        Label { Text("settings.general.button", bundle: .module) } icon: { Image(systemName: "gearshape") }
            .tag(SettingsSection.general)
        Label { Text("settings.status.button", bundle: .module) } icon: { Image(systemName: "waveform.path.ecg") }
            .tag(SettingsSection.status)
        Label { Text("settings.mediaManagers.button", bundle: .module) } icon: { Image(systemName: "server.rack") }
            .tag(SettingsSection.mediaManagers)
        Label { Text("settings.downloadClients.button", bundle: .module) } icon: { Image(systemName: "arrow.down.circle") }
            .tag(SettingsSection.downloadClients)
        Label { Text("settings.mediaServer.label", bundle: .module) } icon: { Image(systemName: "play.tv") }
            .tag(SettingsSection.mediaServer)
        Label { Text("settings.assistant.button", bundle: .module) } icon: { Image(systemName: "sparkles") }
            .tag(SettingsSection.assistant)
        Label { Text("settings.quiz.label", bundle: .module) } icon: { Image(systemName: "rectangle.stack") }
            .tag(SettingsSection.quiz)
        Label { Text("settings.mcp.label", bundle: .module) } icon: { Image(systemName: "point.3.connected.trianglepath.dotted") }
            .tag(SettingsSection.mcp)
        if AppCapabilities.isAppStore {
            Label { Text("settings.icloud.label", bundle: .module) } icon: { Image(systemName: "icloud") }
                .tag(SettingsSection.icloud)
        }
        Label { Text("settings.siriShortcuts.button", bundle: .module) } icon: { Image(systemName: "mic.fill") }
            .tag(SettingsSection.siri)
        Label { Text("settings.about.button", bundle: .module) } icon: { Image(systemName: "info.circle") }
            .tag(SettingsSection.about)
    }

    // MARK: - Sidebar search

    private struct SidebarEntry: Identifiable {
        let section: SettingsSection
        let title: String
        let kind: ServiceKind?
        let systemImage: String
        var isProwlarr: Bool = false
        var id: SettingsSection { section }
    }

    private var sidebarEntries: [SidebarEntry] {
        var items: [SidebarEntry] = [
            .init(section: .general, title: String(localized: "settings.general.button", bundle: .module), kind: nil, systemImage: "gearshape"),
            .init(section: .status, title: String(localized: "settings.status.button", bundle: .module), kind: nil, systemImage: "waveform.path.ecg"),
            .init(section: .mediaManagers, title: String(localized: "settings.mediaManagers.button", bundle: .module), kind: nil, systemImage: "server.rack"),
            .init(section: .downloadClients, title: String(localized: "settings.downloadClients.button", bundle: .module), kind: nil, systemImage: "arrow.down.circle"),
        ]
        items += (mediaManagerSpecs + downloadClientSpecs).map {
            .init(section: .service($0.kind), title: $0.title, kind: $0.kind, systemImage: "")
        }
        items.append(.init(section: .prowlarr, title: "Prowlarr", kind: nil,
                           systemImage: "", isProwlarr: true))
        items += [
            .init(section: .mediaServer, title: String(localized: "settings.mediaServer.label", bundle: .module), kind: nil, systemImage: "play.tv"),
            .init(section: .assistant, title: String(localized: "settings.assistant.button", bundle: .module), kind: nil, systemImage: "sparkles"),
            .init(section: .quiz, title: String(localized: "settings.quiz.label", bundle: .module), kind: nil, systemImage: "rectangle.stack"),
            .init(section: .mcp, title: String(localized: "settings.mcp.label", bundle: .module), kind: nil, systemImage: "point.3.connected.trianglepath.dotted"),
        ]
        if AppCapabilities.isAppStore {
            items.append(.init(section: .icloud, title: String(localized: "settings.icloud.label", bundle: .module), kind: nil, systemImage: "icloud"))
        }
        items += [
            .init(section: .siri, title: String(localized: "settings.siriShortcuts.button", bundle: .module), kind: nil, systemImage: "mic.fill"),
            .init(section: .about, title: String(localized: "settings.about.button", bundle: .module), kind: nil, systemImage: "info.circle"),
        ]
        return items
    }

    private var filteredSidebarEntries: [SidebarEntry] {
        let q = macSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return sidebarEntries.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private func sidebarEntryRow(_ entry: SidebarEntry) -> some View {
        Label {
            Text(verbatim: entry.title)
        } icon: {
            if let kind = entry.kind {
                ServiceIcon(kind: kind, size: 14)
            } else if entry.isProwlarr {
                ServiceIcon(prowlarr: 14)
            } else {
                Image(systemName: entry.systemImage)
            }
        }
        .accessibilityLabel(Text(verbatim: entry.title))
        .tag(entry.section)
    }

    // MARK: - Back/forward history

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < history.count - 1 }

    private func recordHistory(_ section: SettingsSection) {
        if isNavigatingHistory { isNavigatingHistory = false; return }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(section)
        historyIndex = history.count - 1
    }

    private func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        isNavigatingHistory = true
        macSelection = history[historyIndex]
    }

    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        isNavigatingHistory = true
        macSelection = history[historyIndex]
    }

    private func navTitle(for section: SettingsSection) -> Text {
        switch section {
        case .general: return Text("settings.general.button", bundle: .module)
        case .status: return Text("settings.status.button", bundle: .module)
        case .mediaManagers: return Text("settings.mediaManagers.button", bundle: .module)
        case .downloadClients: return Text("settings.downloadClients.button", bundle: .module)
        case .service(let kind): return Text(verbatim: kind.displayName)
        case .prowlarr: return Text(verbatim: "Prowlarr")
        case .mediaServer: return Text("settings.mediaServer.label", bundle: .module)
        case .assistant: return Text("settings.assistant.button", bundle: .module)
        case .quiz: return Text("settings.quiz.label", bundle: .module)
        case .mcp: return Text("settings.mcp.label", bundle: .module)
        case .icloud: return Text("settings.icloud.label", bundle: .module)
        case .siri: return Text("settings.siriShortcuts.button", bundle: .module)
        case .about: return Text("settings.about.button", bundle: .module)
        }
    }
}
#endif
