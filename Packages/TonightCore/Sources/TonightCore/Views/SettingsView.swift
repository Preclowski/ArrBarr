import SwiftUI
import AppKit

/// Settings in the macOS System-Settings shape ArrBarr uses: a flush vibrant
/// sidebar of sections, a detail column with back/forward and a large title.
public struct TonightSettingsView: View {
    @StateObject private var config = TonightConfig.shared
    @ObservedObject private var externalLibrary = ExternalLibraryStore.shared
    @State private var testResult: String?
    @State private var testing = false

    @State private var selection: Section = .general
    /// Back/forward history, System-Settings style. `isNavigatingHistory`
    /// keeps the arrows themselves from recording new entries.
    @State private var history: [Section] = [.general]
    @State private var historyIndex = 0
    @State private var isNavigatingHistory = false

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case general, home, media, about
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .home: return "house"
            case .media: return "chart.bar.doc.horizontal"
            case .about: return "info.circle"
            }
        }
    }

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            sidebarColumn
                .frame(width: 196)
                .background(SidebarVibrancy().ignoresSafeArea())
            Divider().ignoresSafeArea()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 560)
        .onChange(of: selection) { _, newValue in recordHistory(newValue) }
    }

    // MARK: - Chrome

    private var sidebarColumn: some View {
        List(selection: $selection) {
            ForEach(Section.allCases) { section in
                Label { title(for: section) } icon: { Image(systemName: section.symbol) }
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailTopBar
            detailPane
        }
    }

    /// Back/forward as a segmented pill, then the section's large title.
    private var detailTopBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Button { goBack() } label: {
                    Image(systemName: "chevron.backward")
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(historyIndex == 0)
                .help(Text("Back", bundle: .module))
                .accessibilityLabel(Text("Back", bundle: .module))
                Divider().frame(height: 15)
                Button { goForward() } label: {
                    Image(systemName: "chevron.forward")
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(historyIndex >= history.count - 1)
                .help(Text("Forward", bundle: .module))
                .accessibilityLabel(Text("Forward", bundle: .module))
            }
            .buttonStyle(.borderless)
            .font(.body.weight(.medium))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )

            title(for: selection)
                .font(.title2.weight(.bold))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
    }

    private func title(for section: Section) -> Text {
        switch section {
        case .general: return Text("General", bundle: .module)
        case .home: return Text("Home", bundle: .module)
        case .media: return Text("Media Data", bundle: .module)
        case .about: return Text("About", bundle: .module)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .general: generalPane
        case .home: homePane
        case .media: MediaUsagePane()
        case .about: aboutPane
        }
    }

    /// Window-vibrant material so the sidebar reads like a native one.
    private struct SidebarVibrancy: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .sidebar
            view.blendingMode = .behindWindow
            view.state = .followsWindowActiveState
            return view
        }
        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }

    // MARK: - History

    private func recordHistory(_ section: Section) {
        if isNavigatingHistory { isNavigatingHistory = false; return }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(section)
        historyIndex = history.count - 1
    }

    private func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        isNavigatingHistory = true
        selection = history[historyIndex]
    }

    private func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        isNavigatingHistory = true
        selection = history[historyIndex]
    }

    // MARK: - General

    private var generalPane: some View {
        Form {
            SwiftUI.Section {
                SecureField(text: $config.tmdbApiKey) { Text("TMDB API Key", bundle: .module) }
                HStack {
                    Button {
                        testResult = config.importFromArrBarr()
                            ? String(localized: "Imported.", bundle: .module)
                            : String(localized: "ArrBarr key not found.", bundle: .module)
                    } label: {
                        Text("Import from ArrBarr", bundle: .module)
                    }
                    Button {
                        testing = true
                        testResult = nil
                        let tmdb = TMDBService(apiKey: config.tmdbApiKey)
                        Task {
                            do {
                                _ = try await tmdb.trending(.movie)
                                testResult = String(localized: "Key works.", bundle: .module)
                            } catch {
                                testResult = shortDescription(of: error)
                            }
                            testing = false
                        }
                    } label: {
                        Text("Test", bundle: .module)
                    }
                    .disabled(testing || config.tmdbApiKey.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Text(testResult)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("TMDB", bundle: .module)
            }
            SwiftUI.Section {
                LabeledContent {
                    HStack {
                        if externalLibrary.isAvailable, !externalLibrary.sourceNames.isEmpty {
                            Text(String(format: String(localized: "%1$d titles, %2$d watched — %3$@",
                                                       bundle: .module),
                                        externalLibrary.ownedTmdbIds.count,
                                        externalLibrary.watchedTmdbIds.count,
                                        externalLibrary.sourceNames.joined(separator: ", ")))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not connected", bundle: .module)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await externalLibrary.refresh() }
                        } label: {
                            Text("Refresh", bundle: .module)
                        }
                        .disabled(externalLibrary.refreshing || !externalLibrary.isAvailable)
                        if externalLibrary.refreshing { ProgressView().controlSize(.small) }
                    }
                } label: {
                    Text("Library", bundle: .module)
                }
            } header: {
                Text("Library", bundle: .module)
            } footer: {
                Text("Uses ArrBarr's Plex/Radarr/Sonarr connections, read-only.", bundle: .module)
            }
            SwiftUI.Section {
                Picker(selection: $config.watchRegion) {
                    ForEach(["PL", "US", "GB", "DE", "FR", "ES"], id: \.self) { region in
                        Text(region).tag(region)
                    }
                } label: {
                    Text("Streaming Region", bundle: .module)
                }
            } footer: {
                Text("Decides which streaming services are shown on a title.", bundle: .module)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Home

    private var homePane: some View {
        Form {
            SwiftUI.Section {
                Picker(selection: $config.homeHero) {
                    ForEach(HomeHeroKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                } label: {
                    Text("Banner shows", bundle: .module)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Banner", bundle: .module)
            } footer: {
                Text("The big carousel at the top of Home.", bundle: .module)
            }
            SwiftUI.Section {
                ForEach(config.homeSectionOrder) { kind in
                    Toggle(isOn: Binding(
                        get: { !config.hiddenHomeSections.contains(kind) },
                        set: { config.setHomeSection(kind, visible: $0) }
                    )) {
                        Label {
                            Text(kind.title)
                        } icon: {
                            Image(systemName: kind.symbol).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .onMove { source, destination in
                    config.moveHomeSections(from: source, to: destination)
                }
            } header: {
                Text("Rows", bundle: .module)
            } footer: {
                Text("Drag to reorder. Unchecked rows are hidden from Home.", bundle: .module)
            }
            SwiftUI.Section {
                Button {
                    config.resetHomeLayout()
                } label: {
                    Text("Reset to Defaults", bundle: .module)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    private var aboutPane: some View {
        Form {
            SwiftUI.Section {
                LabeledContent {
                    Text(verbatim: Self.versionString).foregroundStyle(.secondary)
                } label: {
                    Text("Version", bundle: .module)
                }
                Link(destination: URL(string: "https://github.com/Preclowski/ArrBarr")!) {
                    Label { Text(verbatim: "GitHub") } icon: { Image(systemName: "link") }
                }
                Text(verbatim: "Made by 🥨")
                    .foregroundStyle(.secondary)
            } header: {
                Text("About", bundle: .module)
            } footer: {
                Text("Pick something to watch tonight.", bundle: .module)
            }
            SwiftUI.Section {
                Toggle(isOn: $config.useServerArtwork) {
                    Text("Use posters from my media server", bundle: .module)
                }
                .disabled(!externalLibrary.hasMediaServer)
            } header: {
                Text("Artwork", bundle: .module)
            } footer: {
                Text(externalLibrary.hasMediaServer
                     ? String(localized: "Titles your server has use its artwork; everything else uses TMDB.", bundle: .module)
                     : String(localized: "Connect Plex, Jellyfin or Emby in ArrBarr to use its artwork.", bundle: .module))
            }
            SwiftUI.Section {
                LabeledContent {
                    Text(verbatim: TonightConfig.supportDirectory.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Text("Data Folder", bundle: .module)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([TonightConfig.storeURL])
                } label: {
                    Text("Show in Finder", bundle: .module)
                }
            } header: {
                Text("Storage", bundle: .module)
            }
            // TMDB's terms require the mark AND this disclaimer under it.
            SwiftUI.Section {
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    Label { Text(verbatim: "TMDB") } icon: { Image(systemName: "globe") }
                }
            } header: {
                Text("Acknowledgements", bundle: .module)
            } footer: {
                Text(verbatim: "This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.")
            }
        }
        .formStyle(.grouped)
    }
}
