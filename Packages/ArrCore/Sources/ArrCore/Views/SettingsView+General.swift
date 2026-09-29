import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

extension SettingsView {
    /// Callers wrap this: macOS gates on `DeveloperMode.isActive`, iOS on `devModeRevealed`.
    @ViewBuilder
    var demoModeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { demoModeOn },
                set: { newValue in
                    guard newValue != demoModeOn else { return }
                    // Ask before flipping local state so a cancelled relaunch keeps the toggle in sync.
                    let committed = onSetDemoMode?(newValue) ?? false
                    if committed { demoModeOn = newValue }
                }
            )) { Text("settings.demoMode.button", bundle: .module) }
            if demoModeOn {
                if let onTestNotification {
                    Button { onTestNotification() } label: { Text("settings.sendTestNotification.button", bundle: .module) }
                }
                if let onShowWelcome {
                    Button { onShowWelcome() } label: { Text("settings.showWelcomeScreen.button", bundle: .module) }
                }
            }
            Button { telemetryReport = configStore.gateway.telemetry.report() } label: { Text("settings.mediaKitTelemetry.button", bundle: .module) }
        } header: { Text("settings.developerOptions.button", bundle: .module) }
        .sheet(isPresented: Binding(get: { telemetryReport != nil }, set: { if !$0 { telemetryReport = nil } })) {
            VStack(alignment: .trailing, spacing: 12) {
                ScrollView {
                    Text(telemetryReport ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { telemetryReport = nil } label: { Text("common.done.button", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .frame(minWidth: 560, minHeight: 380)
        }
    }

    var generalPane: some View {
        Form {
            Section {
                #if os(macOS)
                LaunchAtLoginToggle()
                Picker(selection: $configStore.detachedWindow) {
                    Text("settings.interfaceMode.menuBar", bundle: .module).tag(false)
                    Text("settings.interfaceMode.window", bundle: .module).tag(true)
                } label: { Text("settings.interfaceMode.label", bundle: .module) }
                #endif
                Picker(selection: $configStore.appLanguage) {
                    ForEach(ConfigStore.appLanguageOptions, id: \.code) { opt in
                        // Languages keep their own names; only "System" is translated.
                        (opt.code == "system" ? Text("settings.system.button", bundle: .module) : Text(verbatim: opt.label)).tag(opt.code)
                    }
                } label: { Text("settings.language.button", bundle: .module) }
                themePicker
                textSizePicker
                notificationSoundPicker
            } header: {
                Text("settings.application.button", bundle: .module)
            } footer: {
                if languageChanged {
                    #if os(macOS)
                    HStack(spacing: 8) {
                        Text("settings.restartRequiredToApply.tooltip", bundle: .module)
                        Button { relaunchApp() } label: { Text("settings.relaunch.button", bundle: .module) }
                            .controlSize(.small)
                    }
                    #else
                    Text("settings.quitAndReopenThe.tooltip", bundle: .module)
                    #endif
                }
            }
            // Section order is dragged on the Media-managers page.
            queueGroupingSection
            upcomingSection
            needsYouSection
            tmdbSection
            storageSection
            // No refresh-interval pickers: both intervals are hard-locked (see `ConfigStore.foregroundInterval`).
        }
        .formStyle(.grouped)
    }

    /// macOS only: iOS cannot enumerate `/System/Library/Sounds`.
    @ViewBuilder
    private var notificationSoundPicker: some View {
        #if os(macOS)
        // Play acts on the popup's value, so it sits beside the popup via LabeledContent.
        LabeledContent {
            HStack(spacing: 6) {
                Button { Self.previewSound(named: configStore.notificationSoundName) } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // "Default" is whatever the system picks at delivery time.
                .disabled(configStore.notificationSoundName.isEmpty
                          || configStore.notificationSoundName == ConfigStore.silentSoundName)
                .help(Text("settings.play.button", bundle: .module))
                .accessibilityLabel(Text("settings.play.button", bundle: .module))

                Picker(selection: $configStore.notificationSoundName) {
                    Text("settings.default.button", bundle: .module).tag("")
                    Text("search.none.button", bundle: .module).tag(ConfigStore.silentSoundName)
                    Divider()
                    ForEach(Self.systemSoundNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
            }
        } label: {
            Text("settings.notificationSound.button", bundle: .module)
        }
        .onChange(of: configStore.notificationSoundName) { _, newValue in
            Self.previewSound(named: newValue)
        }
        #endif
    }

    #if os(macOS)
    /// Names that `NSSound(named:)` and `UNNotificationSound(named: "<name>.aiff")` resolve.
    private static let systemSoundNames: [String] = {
        let dir = "/System/Library/Sounds"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }()

    private static func previewSound(named name: String) {
        guard !name.isEmpty, name != ConfigStore.silentSoundName else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
    #endif

    // MARK: - Queue sections

    /// One picker is both the on/off switch and the default disclosure state.
    var queueGroupingSection: some View {
        Section {
            Picker(selection: $queueUI.queueTitleGrouping) {
                Text("settings.queueGrouping.off.option", bundle: .module)
                    .tag(QueueTitleGroupingMode.off)
                Text("settings.queueGrouping.collapsed.option", bundle: .module)
                    .tag(QueueTitleGroupingMode.collapsed)
                Text("settings.queueGrouping.expanded.option", bundle: .module)
                    .tag(QueueTitleGroupingMode.expanded)
            } label: { Text("settings.queueGrouping.label", bundle: .module) }
        } header: { Text("Queue", bundle: .module) }
    }

    /// One switch: the window is hard-locked to 7 days.
    var upcomingSection: some View {
        Section {
            Toggle(isOn: $configStore.showTonight) {
                Text("settings.showUpcomingInQueue.label", bundle: .module)
            }
            Picker(selection: $configStore.tonightVisibleCount) {
                ForEach(ConfigStore.tonightVisibleOptions, id: \.self) { option in
                    if option == 0 {
                        Text("search.all.button", bundle: .module).tag(0)
                    } else {
                        Text(verbatim: "\(option)").tag(option)
                    }
                }
            } label: {
                Text("settings.upcomingVisibleCount.label", bundle: .module)
            }
            .disabled(!configStore.showTonight)
        } header: { Text("Upcoming", bundle: .module) }
    }

    @ViewBuilder
    var storageSection: some View {
        Section {
            LabeledContent {
                if let artworkBytes {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: artworkBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                Text("settings.imageCache.label", bundle: .module)
            }
            Button {
                clearArtworkCache()
            } label: {
                Label { Text("settings.clearImageCache.button", bundle: .module) } icon: { Image(systemName: "trash") }
            }
            .disabled(isClearingArtwork || (artworkBytes ?? 0) == 0)
            LabeledContent {
                if let dataCacheBytes {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: dataCacheBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                Text("settings.dataCache.label", bundle: .module)
            }
            Button {
                clearDataCache()
            } label: {
                Label { Text("settings.clearDataCache.button", bundle: .module) } icon: { Image(systemName: "trash") }
            }
            .disabled(isClearingDataCache || (dataCacheBytes ?? 0) == 0)
        } header: {
            Text("settings.storage.label", bundle: .module)
        }
    }

    func refreshArtworkBytes() {
        Task { artworkBytes = await AppCaches.artworkBytes() }
    }

    func refreshDataCacheBytes() {
        Task { dataCacheBytes = await configStore.gateway.dataCacheBytes() }
    }

    private func clearDataCache() {
        isClearingDataCache = true
        Task {
            await configStore.gateway.purgeDataCache()
            dataCacheBytes = await configStore.gateway.dataCacheBytes()
            isClearingDataCache = false
        }
    }

    private func clearArtworkCache() {
        isClearingArtwork = true
        Task {
            await AppCaches.clearArtwork()
            // The icon tier backs the Spotlight index; restore its thumbnails now.
            SpotlightIndexer.reindex(configStore: configStore)
            artworkBytes = await AppCaches.artworkBytes()
            isClearingArtwork = false
        }
    }

    /// Only the severity picker depends on the section being visible, so only it
    /// is disabled with it.
    @ViewBuilder
    var needsYouSection: some View {
        Section {
            Toggle(isOn: $configStore.showNeedsYou) {
                Text("settings.showSection.label", bundle: .module)
            }
            // iOS is errors-only: ConfigStore forces showWarnings off on every load.
            #if os(macOS)
            Picker(selection: $configStore.showWarnings) {
                Text("settings.errorsOnly.option", bundle: .module).tag(false)
                Text("settings.errorsAndWarnings.option", bundle: .module).tag(true)
            } label: { Text("settings.needsYouSeverity.label", bundle: .module) }
                .disabled(!configStore.showNeedsYou)
            #endif
            Toggle(isOn: $configStore.notifyHealth) {
                Text("settings.notifyHealth.label", bundle: .module)
            }
        } header: { Text("Needs you", bundle: .module) }
    }
}

#if os(macOS)
private struct LaunchAtLoginToggle: View {
    @State private var isOn = LaunchAtLogin.isEnabled

    var body: some View {
        Toggle(isOn: $isOn) { Text("settings.launchAtLogin.button", bundle: .module) }
            .onChange(of: isOn) { _, wanted in
                LaunchAtLogin.set(enabled: wanted)
                isOn = LaunchAtLogin.isEnabled
            }
            // Re-read on show: the item may have been removed in System Settings meanwhile.
            .onAppear { isOn = LaunchAtLogin.isEnabled }
    }
}
#endif
