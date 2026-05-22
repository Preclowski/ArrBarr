import SwiftUI

public struct SearchAddPanel: View {
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

    // Lidarr state
    @State private var selectedMetadataProfileId: Int?

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    hero
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                    Divider().padding(.horizontal, 14)
                    if viewModel.isLoadingOptions {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 16)
                    } else {
                        if result.source == .radarr {
                            radarrForm
                        } else if result.source == .sonarr {
                            sonarrForm
                        } else {
                            lidarrForm
                        }
                    }
                    if let err = viewModel.addError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 14)
                    }
                    addButton
                }
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.loadOptions(source: result.source)
            selectedProfileId = viewModel.qualityProfiles.first?.id
            selectedRootFolder = viewModel.rootFolders.first?.path
            selectedMetadataProfileId = viewModel.metadataProfiles.first?.id
        }
    }

    // MARK: - Header chrome (matches DetailView)

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Image(systemName: result.source.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(result.source.displayName)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            MediaHeaderCard(
                title: result.title,
                subtitle: result.subtitle,
                year: result.year,
                runtime: result.runtime,
                network: result.network,
                certification: result.certification,
                genres: result.genres,
                ratings: ratingChips,
                posterURL: result.posterURL,
                fallbackSymbol: result.source == .sonarr ? "tv" : (result.source == .lidarr ? "music.note" : "film"),
                posterAspect: 2.0/3.0
            )
            if let ov = result.overview, !ov.isEmpty {
                ExpandableOverview(text: ov)
            }
        }
    }

    // MARK: - Lidarr form

    private var lidarrForm: some View {
        VStack(spacing: 4) {
            formPicker("Quality Profile",
                       selection: Binding(
                           get: { selectedProfileId ?? viewModel.qualityProfiles.first?.id ?? 0 },
                           set: { selectedProfileId = $0 }
                       ),
                       options: viewModel.qualityProfiles.map { ($0.id, $0.name) })

            if viewModel.metadataProfiles.count > 1 {
                formPicker("Metadata Profile",
                           selection: Binding(
                               get: { selectedMetadataProfileId ?? viewModel.metadataProfiles.first?.id ?? 0 },
                               set: { selectedMetadataProfileId = $0 }
                           ),
                           options: viewModel.metadataProfiles.map { ($0.id, $0.name) })
            }

            formPicker("Root Folder",
                       selection: Binding(
                           get: { selectedRootFolder ?? viewModel.rootFolders.first?.path ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: viewModel.rootFolders.map { ($0.path, $0.path) })
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private var ratingChips: [RatingChip] {
        var chips: [RatingChip] = []
        if let v = result.imdb { chips.append(RatingChip(label: "IMDb", value: String(format: "%.1f", v), color: .yellow)) }
        if let v = result.rating { chips.append(RatingChip(label: "TMDB", value: String(format: "%.1f", v), color: .teal)) }
        if let v = result.rottenTomatoes { chips.append(RatingChip(label: "RT", value: "\(Int(v))%", color: .red)) }
        if let v = result.metacritic { chips.append(RatingChip(label: "MC", value: "\(Int(v))", color: .green)) }
        return chips
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
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
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
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)
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
            .padding(.horizontal, 14)
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
                } else if result.source == .sonarr {
                    guard let pid = selectedProfileId ?? viewModel.qualityProfiles.first?.id,
                          let folder = selectedRootFolder ?? viewModel.rootFolders.first?.path else { return }
                    await viewModel.addSeries(result, qualityProfileId: pid,
                                             rootFolderPath: folder, monitor: sonarrMonitor,
                                             seriesType: seriesType, seasonFolder: seasonFolder)
                } else {
                    guard let pid = selectedProfileId ?? viewModel.qualityProfiles.first?.id,
                          let folder = selectedRootFolder ?? viewModel.rootFolders.first?.path else { return }
                    let metaPid = selectedMetadataProfileId ?? viewModel.metadataProfiles.first?.id ?? 1
                    await viewModel.addArtist(result, qualityProfileId: pid,
                                             metadataProfileId: metaPid, rootFolderPath: folder)
                }
                if viewModel.addError == nil { onBack() }
            }
        } label: {
            Group {
                if viewModel.isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    let addLabel: String = {
                        switch result.source {
                        case .radarr: return "Add to Radarr"
                        case .sonarr: return "Add to Sonarr"
                        case .lidarr: return "Add to Lidarr"
                        }
                    }()
                    Text(addLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .disabled(viewModel.isAdding || viewModel.isLoadingOptions)
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 14)
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
