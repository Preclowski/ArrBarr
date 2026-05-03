import SwiftUI

struct SettingsView: View {
    var onShowWelcome: (() -> Void)? = nil
    var onTestNotification: (() -> Void)? = nil

    @EnvironmentObject var configStore: ConfigStore
    @State private var draggingKey: String?
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalPane
                    .tabItem { Label("General", systemImage: "gearshape") }
                mediaManagersPane
                    .tabItem { Label("Media Managers", systemImage: "server.rack") }
                usenetPane
                    .tabItem { Label("Usenet", systemImage: "doc.zipper") }
                torrentsPane
                    .tabItem { Label("Torrents", systemImage: "arrow.triangle.2.circlepath") }
            }

            bottomBar
        }
        .environment(\.locale, configStore.currentLocale)
    }

    // MARK: - Panes

    private var mediaManagersPane: some View {
        Form {
            Section("Radarr") {
                ServiceFields(config: $configStore.radarr, kind: .radarr,
                              notifyBinding: $configStore.notifyRadarr)
            }
            Section("Sonarr") {
                ServiceFields(config: $configStore.sonarr, kind: .sonarr,
                              notifyBinding: $configStore.notifySonarr)
            }
            Section("Lidarr") {
                ServiceFields(config: $configStore.lidarr, kind: .lidarr,
                              notifyBinding: $configStore.notifyLidarr)
            }
        }
        .formStyle(.grouped)
    }

    private var usenetPane: some View {
        Form {
            Section("SABnzbd") {
                ServiceFields(config: $configStore.sabnzbd, kind: .sabnzbd)
            }
            Section("NZBGet") {
                ServiceFields(config: $configStore.nzbget, kind: .nzbget)
            }
        }
        .formStyle(.grouped)
    }

    private var torrentsPane: some View {
        Form {
            Section("qBittorrent") {
                ServiceFields(config: $configStore.qbittorrent, kind: .qbittorrent)
            }
            Section("Transmission") {
                ServiceFields(config: $configStore.transmission, kind: .transmission)
            }
            Section("rTorrent") {
                ServiceFields(config: $configStore.rtorrent, kind: .rtorrent)
            }
            Section("Deluge") {
                ServiceFields(config: $configStore.deluge, kind: .deluge)
            }
        }
        .formStyle(.grouped)
    }

    private var generalPane: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $configStore.launchAtLogin)
            }
            Section("Language") {
                Picker("Language", selection: $configStore.appLanguage) {
                    ForEach(ConfigStore.appLanguageOptions, id: \.code) { opt in
                        Text(LocalizedStringKey(opt.label)).tag(opt.code)
                    }
                }
            }
            Section("Section order") {
                ForEach(configStore.arrOrder, id: \.self) { key in
                    arrOrderRow(key: key)
                }
            }
            Section("Popover") {
                Toggle("Show indexer issues warning", isOn: $configStore.showIndexerIssues)
                Picker("Tonight window", selection: $configStore.tonightHours) {
                    ForEach(ConfigStore.tonightHoursOptions, id: \.self) { hours in
                        Text(Self.formatTonight(hours: hours)).tag(hours)
                    }
                }
                .disabled(!configStore.showTonight)
            }
            Section("Refresh Interval") {
                Picker("Popover open", selection: $configStore.foregroundInterval) {
                    ForEach(ConfigStore.foregroundIntervalOptions, id: \.self) { interval in
                        Text(Self.formatInterval(interval)).tag(interval)
                    }
                }
                Picker("Background", selection: $configStore.backgroundInterval) {
                    ForEach(ConfigStore.backgroundIntervalOptions, id: \.self) { interval in
                        Text(Self.formatInterval(interval)).tag(interval)
                    }
                }
            }
            if onShowWelcome != nil || onTestNotification != nil {
                Section {
                    if let onTestNotification {
                        Button("Send test notification") { onTestNotification() }
                    }
                    if let onShowWelcome {
                        Button("Show welcome screen") { onShowWelcome() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static let arrRowHeight: CGFloat = 24

    @ViewBuilder
    private func arrOrderRow(key: String) -> some View {
        if let spec = orderRowSpec(for: key) {
            let isDragging = draggingKey == key
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                Image(systemName: spec.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(spec.title)
                Spacer()
                if let toggle = visibilityToggle(for: key) {
                    Toggle("", isOn: toggle)
                        .labelsHidden()
                        .controlSize(.small)
                        .toggleStyle(.switch)
                }
            }
            .frame(height: Self.arrRowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDragging ? Color.primary.opacity(0.08) : .clear)
                    .padding(.horizontal, -6)
            )
            .offset(y: isDragging ? dragOffset : 0)
            .zIndex(isDragging ? 1 : 0)
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: configStore.arrOrder)
            .gesture(arrDragGesture(key: key))
        }
    }

    private struct OrderRowSpec {
        let title: LocalizedStringKey
        let symbol: String
    }

    private func visibilityToggle(for key: String) -> Binding<Bool>? {
        if key == ConfigStore.tonightOrderKey { return $configStore.showTonight }
        if key == ConfigStore.needsYouOrderKey { return $configStore.showNeedsYou }
        return nil
    }

    private func orderRowSpec(for key: String) -> OrderRowSpec? {
        if key == ConfigStore.tonightOrderKey {
            return .init(title: "Tonight", symbol: "moon.stars.fill")
        }
        if key == ConfigStore.needsYouOrderKey {
            return .init(title: "Needs you", symbol: "exclamationmark.bubble.fill")
        }
        if let source = QueueItem.Source(rawValue: key) {
            return .init(title: LocalizedStringKey(source.displayName), symbol: source.symbol)
        }
        return nil
    }

    private func arrDragGesture(key: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if draggingKey != key { draggingKey = key }
                dragOffset = value.translation.height

                guard let from = configStore.arrOrder.firstIndex(of: key) else { return }
                let steps = Int((dragOffset / Self.arrRowHeight).rounded())
                let target = max(0, min(configStore.arrOrder.count - 1, from + steps))
                if target != from {
                    var newOrder = configStore.arrOrder
                    let item = newOrder.remove(at: from)
                    newOrder.insert(item, at: target)
                    configStore.arrOrder = newOrder
                    dragOffset -= CGFloat(target - from) * Self.arrRowHeight
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    draggingKey = nil
                    dragOffset = 0
                }
            }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(Self.versionString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help("ArrBarr \(Self.versionString)")
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(verbatim: "🥨 Precel")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://github.com/Preclowski/ArrBarr")!) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .help("github.com/Preclowski/ArrBarr")
                Spacer()
                Button("Close") { NSApp.keyWindow?.close() }
                    .keyboardShortcut("w", modifiers: .command)
                    .modifier(GlassButtonStyle())
                    .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return short == build ? "v\(short)" : "v\(short) (\(build))"
    }

    private static func formatInterval(_ seconds: TimeInterval) -> String {
        if seconds == 0 {
            return String(localized: "Never")
        } else if seconds < 60 {
            return "\(Int(seconds))s"
        } else {
            return "\(Int(seconds) / 60)m"
        }
    }

    private static func formatTonight(hours: Int) -> String {
        if hours < 24 {
            return String(format: String(localized: "%lld hours"), hours)
        }
        let days = hours / 24
        if days == 1 { return String(localized: "24 hours") }
        return String(format: String(localized: "%lld days"), days)
    }
}

private struct ServiceFields: View {
    @Binding var config: ServiceConfig
    let kind: ServiceKind
    var notifyBinding: Binding<Bool>? = nil

    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    var body: some View {
        Toggle("Enabled", isOn: $config.enabled.animation())

        if config.enabled, let notifyBinding {
            Toggle("Notify on new grabs", isOn: notifyBinding)
        }

        if config.enabled {
            TextField("URL", text: $config.baseURL, prompt: Text(kind.urlPlaceholder))
                .autocorrectionDisabled(true)

            if kind.requiresApiKey {
                SecureField("API Key", text: $config.apiKey, prompt: Text("Paste your API key"))
            }

            if kind.requiresLogin {
                TextField("Username", text: $config.username, prompt: Text("admin"))
                    .autocorrectionDisabled(true)
                SecureField("Password", text: $config.password, prompt: Text("Password"))
            }

            HStack(spacing: 8) {
                Button("Test Connection") { runTest() }
                    .modifier(GlassButtonStyle())
                    .controlSize(.small)
                    .disabled(testState == .testing || !config.isConfigured)

                switch testState {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView().controlSize(.small)
                case .success(let msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(msg)
                }
            }
            .onChange(of: config) { _, _ in
                if testState != .idle && testState != .testing { testState = .idle }
            }
        }
    }

    private func runTest() {
        testState = .testing
        let snapshot = config
        let kind = self.kind
        Task {
            do {
                let result = try await ConnectionTester.test(kind: kind, config: snapshot)
                await MainActor.run { testState = .success(result) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { testState = .failure(message) }
            }
        }
    }
}

private enum ConnectionTester {
    static func test(kind: ServiceKind, config: ServiceConfig) async throws -> String {
        switch kind {
        case .radarr:       return try await RadarrClient(config: config).testConnection()
        case .sonarr:       return try await SonarrClient(config: config).testConnection()
        case .lidarr:       return try await LidarrClient(config: config).testConnection()
        case .sabnzbd:      return try await SabnzbdClient(config: config).testConnection()
        case .nzbget:       return try await NzbgetClient(config: config).testConnection()
        case .qbittorrent:  return try await QbittorrentClient(config: config).testConnection()
        case .transmission: return try await TransmissionClient(config: config).testConnection()
        case .rtorrent:     return try await RtorrentClient(config: config).testConnection()
        case .deluge:       return try await DelugeClient(config: config).testConnection()
        }
    }
}
