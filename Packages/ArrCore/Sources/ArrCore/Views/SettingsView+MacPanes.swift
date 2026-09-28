import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

#if os(macOS)
extension SettingsView {
    private var aiPane: some View {
        Form {
            aiSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    func detailPane(for section: SettingsSection) -> some View {
        switch section {
        case .general: generalPane
        case .status: ServerStatusView()
        case .mediaManagers: serviceHubPane(mediaManagerSpecs, locked: false, reorderable: true)
        case .downloadClients: serviceHubPane(downloadClientSpecs, locked: true)
        case .service(let kind): singleServicePane(for: kind)
        case .prowlarr: prowlarrPane
        case .mediaServer: MediaServerSettingsPane()
        case .assistant: aiPane
        case .quiz: QuizSettingsPane()
        case .mcp: MCPSettingsPane()
        case .icloud: ICloudSettingsView()
        case .siri: siriPane
        case .about: aboutPane
        }
    }

    /// Hub page: cards drill into a service page via `macSelection`. `reorderable`
    /// makes the card order the queue's section order.
    private func serviceHubPane(
        _ specs: [ServiceSpec],
        locked: Bool,
        reorderable: Bool = false
    ) -> some View {
        Form {
            Section {
                ForEach(reorderable ? orderedByQueueSections(specs) : specs) { spec in
                    Button {
                        macSelection = .service(spec.kind)
                    } label: {
                        HStack(spacing: 10) {
                            // Grip, brand mark and chevron are decoration; `.onMove` has its own VoiceOver affordance.
                            if reorderable {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.tertiary)
                                    .scaledFont(size: 11)
                                    .accessibilityHidden(true)
                            }
                            ServiceIcon(kind: spec.kind, size: 18)
                                .accessibilityHidden(true)
                            Text(verbatim: spec.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            // Live health dot, not a "configured" tick: a tick lies when the service is unreachable.
                            if spec.config.wrappedValue.isConfigured {
                                ConnectionStatusDot(service: .arr(spec.kind))
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onMove(perform: reorderable ? moveMediaManagers : nil)
                // Prowlarr sits outside the `ForEach`, so it has no grip and never reorders.
                if reorderable {
                    Button {
                        macSelection = .prowlarr
                    } label: {
                        prowlarrRowLabel
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                if reorderable {
                    Text("settings.dragToReorderQueue.footer", bundle: .module)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(locked && !storeManager.isPro)
        .overlay {
            if locked && !storeManager.isPro {
                ProLockOverlay(feature: .downloadClients)
            }
        }
    }

    @ViewBuilder
    private func singleServicePane(for kind: ServiceKind) -> some View {
        if let spec = (mediaManagerSpecs + downloadClientSpecs).first(where: { $0.kind == kind }) {
            let isDownloadClient = downloadClientSpecs.contains { $0.kind == kind }
            Form {
                Section {
                    serviceFields(spec)
                } header: { serviceSectionHeader(spec.kind, LocalizedStringKey(spec.title)) }
            }
            .formStyle(.grouped)
            .disabled(isDownloadClient && !storeManager.isPro)
            .overlay {
                if isDownloadClient && !storeManager.isPro {
                    ProLockOverlay(feature: .downloadClients)
                }
            }
        }
    }

    private var prowlarrPane: some View {
        Form {
            Section {
                prowlarrFields
            } header: { prowlarrHeader }
        }
        .formStyle(.grouped)
    }

    private var siriPane: some View {
        Form {
            SiriShortcutsSettingsContent()
        }
        .formStyle(.grouped)
    }

    private var aboutPane: some View {
        Form {
            if DeveloperMode.isActive {
                demoModeSection
            }
            Section {
                LabeledContent {
                    Text(Self.versionString).foregroundStyle(.secondary)
                } label: {
                    Text("settings.version.button", bundle: .module)
                }
                Link(destination: URL(string: "https://github.com/Preclowski/ArrBarr")!) {
                    Label { Text(verbatim: "GitHub") } icon: { Image(systemName: "link") }
                }
                Link(destination: URL(string: "https://arrbarr.app")!) {
                    Label { Text("settings.website.button", bundle: .module) } icon: { Image(systemName: "globe") }
                }
                Link(destination: URL(string: "https://arrbarr.app/privacy")!) {
                    Label { Text("settings.privacyPolicy.button", bundle: .module) } icon: { Image(systemName: "hand.raised") }
                }
                Text(verbatim: "Made by 🥨")
                    .foregroundStyle(.secondary)
            } header: { Text("settings.about.button", bundle: .module) }
            // Plain rows, no glyphs: attribution, not actions.
            Section {
                Link(destination: URL(string: "https://dashboardicons.com")!) {
                    Text(verbatim: "Dashboard Icons — CC BY 4.0")
                }
                Link(destination: URL(string: "https://selfh.st/icons")!) {
                    Text(verbatim: "selfh.st Icons — CC BY 4.0")
                }
            } header: { Text("settings.acknowledgements.button", bundle: .module) } footer: {
                Text("settings.serviceIconsByDashboard.tooltip", bundle: .module)
            }
            // TMDB's terms require the mark and this disclaimer under their own row.
            // Verbatim: a licence notice, not UI copy.
            Section {
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    Label {
                        Text(verbatim: "TMDB")
                    } icon: {
                        // `brand-tmdb` is a template asset and gets tinted; TMDB's mark must keep its colours.
                        Image("rating-tmdb", bundle: .module)
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                }
            } footer: {
                Text(verbatim: "This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.")
            }
        }
        .formStyle(.grouped)
    }

    func relaunchApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
#endif
