import SwiftUI

#if os(iOS)
extension SettingsView {
    var iOSCombinedForm: some View {
        List {
            iosSettingsLink("settings.general.button", systemImage: "gearshape") { iosGeneralForm }
            iosSettingsLink("settings.status.button", systemImage: "waveform.path.ecg") { ServerStatusView() }
            iosSettingsLink("Media managers", systemImage: "server.rack") { iosMediaManagersForm }
            iosSettingsLink("Download clients", systemImage: "arrow.down.circle") { iosDownloadClientsForm }
            iosSettingsLink("settings.mediaServer.label", systemImage: "play.tv") { MediaServerSettingsPane() }
            iosSettingsLink("settings.assistant.button", systemImage: "sparkles") { iosAIForm }
            iosSettingsLink("settings.quiz.label", systemImage: "rectangle.stack") { QuizSettingsPane() }
            if AppCapabilities.isAppStore {
                iosSettingsLink("iCloud", systemImage: "icloud") { ICloudSettingsView() }
            }
            iosSettingsLink("settings.siriShortcuts.button", systemImage: "mic.fill") { iosSiriForm }
            iosSettingsLink("settings.about.button", systemImage: "info.circle") { iosAboutForm }
        }
    }

    @ViewBuilder
    private var iosSiriForm: some View {
        Form {
            SiriShortcutsSettingsContent()
        }
        .navigationTitle(Text("settings.siriShortcuts.button", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func iosSettingsLink<Destination: View>(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label { Text(titleKey, bundle: .module) } icon: { Image(systemName: systemImage) }
        }
    }

    private func iosServiceLink<Content: View>(
        kind: ServiceKind,
        title: String,
        configured: Bool,
        @ViewBuilder fields: @escaping () -> Content
    ) -> some View {
        NavigationLink {
            Form { Section { fields() } }
                .navigationTitle(Text(verbatim: title))
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack(spacing: 10) {
                ServiceIcon(kind: kind, size: 18)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                Spacer()
                if configured {
                    ConnectionStatusDot(service: .arr(kind))
                }
            }
        }
    }

    private var iosMediaManagersForm: some View {
        iosServiceList(mediaManagerSpecs, title: "Media managers", reorderable: true)
    }

    private var iosDownloadClientsForm: some View {
        iosServiceList(downloadClientSpecs, title: "Download clients")
            .disabled(!storeManager.isPro)
            .overlay {
                if !storeManager.isPro {
                    ProLockOverlay(feature: .downloadClients)
                }
            }
    }

    /// Media managers are `reorderable` (section order); `.onMove` needs edit mode
    /// on iOS, hence the EditButton.
    private func iosServiceList(_ specs: [ServiceSpec], title: LocalizedStringKey,
                                reorderable: Bool = false) -> some View {
        List {
            Section {
                ForEach(reorderable ? orderedByQueueSections(specs) : specs) { spec in
                    iosServiceLink(kind: spec.kind, title: spec.title,
                                   configured: spec.config.wrappedValue.isConfigured) {
                        serviceFields(spec)
                    }
                }
                .onMove(perform: reorderable ? moveMediaManagers : nil)
                // Outside the `ForEach`: Prowlarr is no queue source, nothing to reorder against.
                if reorderable {
                    NavigationLink {
                        Form { Section { prowlarrFields } }
                            .navigationTitle(Text(verbatim: "Prowlarr"))
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        prowlarrRowLabel
                    }
                }
            } footer: {
                if reorderable {
                    Text("settings.dragToReorderQueue.footer", bundle: .module)
                }
            }
        }
        .navigationTitle(Text(title, bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if reorderable {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
    }

    private var iosAIForm: some View {
        Form { aiSection }
            .navigationTitle(Text("settings.assistant.button", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
    }

    private var iosGeneralForm: some View {
        Form {
            // No language picker on iOS: ConfigStore forces "system".
            queueGroupingSection
            upcomingSection
            needsYouSection
            tmdbSection
            storageSection
            // No theme, warnings or refresh-interval controls on iOS: ConfigStore forces them.
        }
        .navigationTitle(Text("settings.general.button", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var iosAboutForm: some View {
        Form {
            if devModeRevealed {
                demoModeSection
            }
            Section {
                // 7 taps reveal Developer options. LabeledContent swallows gestures inside
                // Form, so a Button styled as a row.
                Button {
                    versionTapCount += 1
                    if versionTapCount >= 7 && !devModeRevealed {
                        DeveloperMode.setEnabled(true)
                        withAnimation(.smooth(duration: 0.22)) { devModeRevealed = true }
                    }
                } label: {
                    HStack {
                        Text("settings.version.button", bundle: .module)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(Self.versionString)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
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
        .navigationTitle(Text("settings.about.button", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
