import SwiftUI

public struct SearchAddPanel: View {
    /// Mutable so we can swap in an enriched copy when the source was a
    /// chat result built from a TMDB summary (no IMDB / RT / runtime).
    /// `+`-flow results already arrive enriched and the swap is a no-op.
    @State private var result: SearchResult
    @ObservedObject var viewModel: SearchViewModel
    let onBack: () -> Void

    public init(result: SearchResult, viewModel: SearchViewModel,
                onBack: @escaping () -> Void) {
        _result = State(initialValue: result)
        self.viewModel = viewModel
        self.onBack = onBack
    }

    // Radarr state
    @State private var selectedProfileId: Int?
    @State private var selectedRootFolder: String?
    @State private var radarrMonitor: RadarrMonitorMode = .movieOnly

    // Sonarr state
    @State private var sonarrMonitor: SonarrMonitorMode = .all
    @State private var seriesType: SonarrSeriesType = .standard
    /// Season folders default to on for every series we add. The toggle
    /// used to live in the form but it was a power-user knob that almost
    /// nobody flipped — Sonarr's own default is the same. Constant `true`
    /// keeps the API call shape compatible without re-surfacing UI.
    private let seasonFolder = true

    // Lidarr state
    @State private var selectedMetadataProfileId: Int?

    // Whisparr state
    @State private var whisparrMonitor: RadarrMonitorMode = .movieOnly
    /// Poster lightbox — set to a URL when the user taps the hero
    /// poster, cleared by the xmark / scrim tap. Renders the shared
    /// `PosterLightbox` as a ZStack overlay so the focused view
    /// covers the entire popover (form + scroll).
    @State private var enlargedPoster: URL?

    public var body: some View {
        ZStack {
            mainContent
                // Hide the form + scroll while the lightbox is up so
                // the frosted scrim doesn't blur a visible layout
                // underneath. Same pattern DetailView uses.
                .opacity(enlargedPoster != nil ? 0 : 1)
                .allowsHitTesting(enlargedPoster == nil)

            if let url = enlargedPoster {
                PosterLightbox(
                    url: url,
                    apiKey: nil,
                    aspectRatio: result.source == .lidarr ? 1.0 : 2.0 / 3.0,
                    onDismiss: {
                        withAnimation(.smooth(duration: 0.22)) { enlargedPoster = nil }
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header

            // Scrollable content — hero card + overview only. The
            // parameter form + Add CTA used to live in here at the
            // bottom of the scroll; the user reported having to scroll
            // past a tall overview just to find the action. Pinned
            // them to a sticky footer below so the CTA is always one
            // tap away.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    hero
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                }
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            // Sticky footer — parameter form + glass CTA pinned to
            // the bottom of the popover. Thin material backdrop +
            // divider so the footer reads as a distinct surface
            // floating above the scroll content.
            VStack(spacing: 6) {
                if viewModel.isLoadingOptions {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                } else {
                    if result.source == .radarr {
                        radarrForm
                    } else if result.source == .sonarr {
                        sonarrForm
                    } else if result.source == .whisparr {
                        whisparrForm
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
                    .padding(.bottom, 10)
            }
            .padding(.top, 8)
            .background(
                Rectangle()
                    .fill(.thinMaterial)
                    .overlay(alignment: .top) {
                        Divider().opacity(0.4)
                    }
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Enrich first so the hero card upgrades from TMDB-lean to
            // full-fat IMDB/RT/runtime as soon as possible. Runs in
            // parallel with loadOptions — they hit different endpoints.
            async let enrich: Void = {
                if needsEnrichment, let enriched = await viewModel.enrich(result) {
                    result = enriched
                }
            }()
            async let options: Void = viewModel.loadOptions(source: result.source)
            _ = await (enrich, options)
            selectedProfileId = viewModel.qualityProfiles.first?.id
            selectedRootFolder = viewModel.rootFolders.first?.path
            selectedMetadataProfileId = viewModel.metadataProfiles.first?.id
        }
    }

    /// TMDB-sourced chat results carry only voteAverage + title + year + genres.
    /// Lookup-sourced `+` results carry IMDB / RT / Metacritic / runtime too.
    /// Use those richer fields' absence as the "this came from chat" signal.
    private var needsEnrichment: Bool {
        result.runtime == nil && result.imdb == nil
            && result.rottenTomatoes == nil && result.metacritic == nil
    }

    // MARK: - Header chrome (matches DetailView)

    private var header: some View {
        // Variant A — back + page title leading, source tag trailing.
        // Same shape as HistoryView and DetailView so all three back-
        // navigable screens read consistently.
        HStack(spacing: 6) {
            FloatingBackButton(action: onBack)

            Text("Add", bundle: .module)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Image(systemName: result.source.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(result.source.displayName)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
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
                fallbackSymbol: result.source == .sonarr ? "tv" : (result.source == .lidarr ? "music.note" : (result.source == .whisparr ? "flame" : "film")),
                posterAspect: 2.0/3.0,
                onPosterTap: { url in
                    withAnimation(.smooth(duration: 0.22)) {
                        enlargedPoster = url ?? result.posterURL
                    }
                }
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

    // MARK: - Whisparr form

    private var whisparrForm: some View {
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
                       selection: $whisparrMonitor,
                       options: RadarrMonitorMode.allCases.map { ($0, $0.displayName) })
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
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
            // Match the 14pt horizontal inset every other form here uses
            // (radarrForm / whisparrForm / lidarrForm). Without it the
            // picker capsules touch the popover edge while the section
            // labels and chips around them are inset — reads as wonky.
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
            .padding(.horizontal, 14)

            sectionLabel("Monitor")
            monitorChips
        }
        .padding(.bottom, 4)
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
                } else if result.source == .whisparr {
                    guard let pid = selectedProfileId ?? viewModel.qualityProfiles.first?.id,
                          let folder = selectedRootFolder ?? viewModel.rootFolders.first?.path else { return }
                    await viewModel.addScene(result, qualityProfileId: pid,
                                            rootFolderPath: folder, monitor: whisparrMonitor)
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
                        case .whisparr: return "Add to Whisparr"
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
