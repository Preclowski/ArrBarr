import SwiftUI

struct SearchAddPanel: View {
    let result: SearchResult
    @ObservedObject var viewModel: SearchViewModel
    let onBack: () -> Void

    // Radarr state
    @State private var selectedProfileId: Int?
    @State private var selectedRootFolder: String?
    @State private var radarrMonitor: RadarrMonitorMode = .movieOnly

    // Sonarr state
    @State private var sonarrMonitor: SonarrMonitorMode = .all
    @State private var seriesType: SonarrSeriesType = .standard
    @State private var seasonFolder = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Results")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Spacer()
                Text(result.source == .radarr ? "Add to Radarr" : "Add to Sonarr")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    Divider().padding(.vertical, 8)
                    if viewModel.isLoadingOptions {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 16)
                    } else {
                        if result.source == .radarr {
                            radarrForm
                        } else {
                            sonarrForm
                        }
                    }
                    if let err = viewModel.addError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    }
                    addButton
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 480)
        }
        .task {
            await viewModel.loadOptions(source: result.source)
            selectedProfileId = viewModel.qualityProfiles.first?.id
            selectedRootFolder = viewModel.rootFolders.first?.path
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 10) {
            RemotePoster(url: result.posterURL, apiKey: nil,
                         size: CGSize(width: 44, height: 64), cornerRadius: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(2)

                HStack(spacing: 4) {
                    if let y = result.year { Text(verbatim: "\(y)").foregroundStyle(.secondary) }
                    if let r = result.rating {
                        Text("·").foregroundStyle(.tertiary)
                        Text(String(format: "★%.1f", r)).foregroundStyle(.secondary)
                    }
                    if let rt = result.runtime {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(rt)m").foregroundStyle(.secondary)
                    }
                    if let sub = result.subtitle {
                        Text("·").foregroundStyle(.tertiary)
                        Text(sub).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10))

                if let ov = result.overview {
                    Text(ov)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    // MARK: - Radarr form

    private var radarrForm: some View {
        VStack(spacing: 4) {
            formPicker("Quality Profile",
                       selection: Binding(
                           get: { selectedProfileId ?? viewModel.qualityProfiles.first?.id ?? 0 },
                           set: { selectedProfileId = $0 }
                       ),
                       options: viewModel.qualityProfiles.map { ($0.id, $0.name) })

            formPicker("Root Folder",
                       selection: Binding(
                           get: { selectedRootFolder ?? viewModel.rootFolders.first?.path ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: viewModel.rootFolders.map { ($0.path, $0.path) })

            formPicker("Monitor",
                       selection: $radarrMonitor,
                       options: RadarrMonitorMode.allCases.map { ($0, $0.displayName) })
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Sonarr form

    private var sonarrForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Library")
            VStack(spacing: 4) {
                formPicker("Quality Profile",
                           selection: Binding(
                               get: { selectedProfileId ?? viewModel.qualityProfiles.first?.id ?? 0 },
                               set: { selectedProfileId = $0 }
                           ),
                           options: viewModel.qualityProfiles.map { ($0.id, $0.name) })

                formPicker("Root Folder",
                           selection: Binding(
                               get: { selectedRootFolder ?? viewModel.rootFolders.first?.path ?? "" },
                               set: { selectedRootFolder = $0 }
                           ),
                           options: viewModel.rootFolders.map { ($0.path, $0.path) })

                formPicker("Series Type",
                           selection: $seriesType,
                           options: SonarrSeriesType.allCases.map { ($0, $0.displayName) })
            }

            sectionLabel("Monitor")
            monitorChips

            Toggle(isOn: $seasonFolder) {
                Text("Season Folders")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }

    private var monitorChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(SonarrMonitorMode.allCases) { mode in
                    Button {
                        sonarrMonitor = mode
                    } label: {
                        Text(mode.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(sonarrMonitor == mode
                                ? Color.accentColor.opacity(0.2)
                                : Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(sonarrMonitor == mode ? Color.accentColor : .secondary)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(sonarrMonitor == mode ? Color.accentColor.opacity(0.4) : Color.clear,
                                        lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Add button

    private var addButton: some View {
        Button {
            Task {
                if result.source == .radarr {
                    guard let pid = selectedProfileId ?? viewModel.qualityProfiles.first?.id,
                          let folder = selectedRootFolder ?? viewModel.rootFolders.first?.path else { return }
                    await viewModel.addMovie(result, qualityProfileId: pid,
                                            rootFolderPath: folder, monitor: radarrMonitor)
                } else {
                    guard let pid = selectedProfileId ?? viewModel.qualityProfiles.first?.id,
                          let folder = selectedRootFolder ?? viewModel.rootFolders.first?.path else { return }
                    await viewModel.addSeries(result, qualityProfileId: pid,
                                             rootFolderPath: folder, monitor: sonarrMonitor,
                                             seriesType: seriesType, seasonFolder: seasonFolder)
                }
                if viewModel.addError == nil { onBack() }
            }
        } label: {
            Group {
                if viewModel.isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    Text(result.source == .radarr ? "Add to Radarr" : "Add to Sonarr")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .disabled(viewModel.isAdding || viewModel.isLoadingOptions)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func formPicker<T: Hashable>(_ label: String, selection: Binding<T>,
                                         options: [(T, String)]) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(options, id: \.0) { val, name in
                    Button(name) { selection.wrappedValue = val }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(options.first(where: { $0.0 == selection.wrappedValue })?.1
                         ?? options.first?.1 ?? "—")
                        .font(.system(size: 11))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
