import SwiftUI
import MediaKit

/// What the detail header's pencil opens — the record being edited.
struct MediaEditRequest: Identifiable, Hashable {
    let source: QueueItem.Source
    /// Movie / series id, or the ARTIST id for Lidarr (albums have no editable profile).
    let entityId: Int
    var id: String { "\(source.rawValue)-edit-\(entityId)" }
}

/// Edit modal for an in-library movie / series / artist. macOS hosts it in
/// `MediaEditModalOverlay`, iOS as a native sheet.
struct MediaEditPanel: View {
    let request: MediaEditRequest
    let onBack: () -> Void
    /// Fired once `load()` settles; the macOS overlay stays invisible until then.
    var onReady: (() -> Void)? = nil

    @EnvironmentObject private var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared

    @State private var qualityProfiles: [ArrQualityProfile] = []
    @State private var metadataProfiles: [ArrMetadataProfile] = []
    @State private var rootFolders: [String] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var saving = false
    @State private var saveError: String?

    @State private var selectedProfileId: Int?
    @State private var selectedMetadataProfileId: Int?
    @State private var selectedRootFolder: String?
    @State private var availability: RadarrMinimumAvailability = .released
    @State private var seriesType: SonarrSeriesType = .standard
    /// Sonarr's values are "all" / "none"; Lidarr adds "new".
    @State private var monitorNewItems = "all"
    @State private var seasonFolder = true
    /// A differing selection saves with `moveFiles=true`.
    @State private var originalRootFolder: String?

    #if os(iOS)
    /// Sizes the sheet, so Dynamic Type grows it instead of scrolling inside it.
    @ScaledMetric(relativeTo: .body) private var formRowHeight: CGFloat = 44
    #endif

    var body: some View {
        // iOS gets a real Form: the card's 11pt rows and mini switches are desktop controls.
        #if os(iOS)
        iosForm
            .task(id: request.id) { await load() }
        #else
        macCard
            .task(id: request.id) { await load() }
        #endif
    }

    #if os(iOS)
    private var iosForm: some View {
        NavigationStack {
            Group {
                if loading {
                    LoadingStateView(label: nil).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = loadError {
                    LoadErrorLine(message: err).padding()
                } else {
                    Form {
                        Section { iosFields }
                        if movesFiles {
                            Section {
                                Label { Text("edit.moveNote.label", bundle: .module) }
                                icon: { Image(systemName: "exclamationmark.triangle.fill") }
                                    .foregroundStyle(.orange)
                                    .font(.footnote)
                            }
                        }
                        if let err = saveError {
                            Section { Text(err).foregroundStyle(.red).font(.footnote) }
                        }
                    }
                }
            }
            .navigationTitle(Text("detail.edit.button", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            // Fitted rather than `.medium`, a fixed half screen whatever the content.
            .presentationDetents([.height(fittedSheetHeight), .large])
            .presentationDragIndicator(.visible)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) { Text("common.cancel.button", bundle: .module) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            HStack(spacing: 4) {
                                if !storeManager.isPro { Image(systemName: "lock.fill") }
                                // "Save changes" crowds the title out of an iOS bar.
                                Text("common.save.button", bundle: .module)
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(saving || loading)
                }
            }
        }
    }

    private var fieldRowCount: Int {
        var rows = 2  // quality profile + root folder, every source
        switch request.source {
        case .radarr, .whisparr: rows += 1                       // availability
        case .sonarr: rows += 3                                  // type, monitor, season folder
        case .lidarr: rows += metadataProfiles.isEmpty ? 1 : 2   // (metadata) + monitor
        }
        return rows
    }

    private var fittedSheetHeight: CGFloat {
        // Nav bar + the grouped section's own top/bottom insets + grabber.
        let chrome: CGFloat = 132
        guard !loading, loadError == nil else { return 180 }
        let extras = (movesFiles ? formRowHeight : 0) + (saveError == nil ? 0 : formRowHeight)
        return CGFloat(fieldRowCount) * formRowHeight + chrome + extras
    }

    @ViewBuilder
    private var iosFields: some View {
        Picker(selection: Binding(
            get: { selectedProfileId ?? qualityProfiles.first?.id ?? 0 },
            set: { selectedProfileId = $0 }
        )) {
            ForEach(qualityProfiles, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
        } label: {
            Text("search.qualityProfile.button", bundle: .module)
        }

        switch request.source {
        case .radarr, .whisparr:
            Picker(selection: $availability) {
                ForEach(RadarrMinimumAvailability.allCases, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
            } label: {
                Text("edit.availability.button", bundle: .module)
            }
        case .sonarr:
            Picker(selection: $seriesType) {
                ForEach(SonarrSeriesType.allCases, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
            } label: {
                Text("search.seriesType.button", bundle: .module)
            }
            Picker(selection: $monitorNewItems) {
                Text("search.all.button", bundle: .module).tag("all")
                Text("search.none.button", bundle: .module).tag("none")
            } label: {
                Text("edit.monitorNewSeasons.button", bundle: .module)
            }
            Toggle(isOn: $seasonFolder) { Text("edit.seasonFolder.button", bundle: .module) }
        case .lidarr:
            if !metadataProfiles.isEmpty {
                Picker(selection: Binding(
                    get: { selectedMetadataProfileId ?? metadataProfiles.first?.id ?? 0 },
                    set: { selectedMetadataProfileId = $0 }
                )) {
                    ForEach(metadataProfiles, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
                } label: {
                    Text("search.metadataProfile.button", bundle: .module)
                }
            }
            Picker(selection: $monitorNewItems) {
                Text("search.all.button", bundle: .module).tag("all")
                Text("edit.newItems.button", bundle: .module).tag("new")
                Text("search.none.button", bundle: .module).tag("none")
            } label: {
                Text("edit.monitorNewAlbums.button", bundle: .module)
            }
        }

        Picker(selection: Binding(
            get: { selectedRootFolder ?? rootFolders.first ?? "" },
            set: { selectedRootFolder = $0 }
        )) {
            ForEach(rootFolders, id: \.self) { Text(verbatim: $0).tag($0) }
        } label: {
            Text("search.rootFolder.button", bundle: .module)
        }
    }
    #endif

    private var macCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("detail.edit.button", bundle: .module)
                    .scaledFont(size: 14, weight: .semibold)
                Spacer(minLength: 0)
                PanelCloseButton(action: onBack)
            }
            .padding(.horizontal, 14)

            if loading {
                LoadingStateView(label: nil)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let err = loadError {
                LoadErrorLine(message: err)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                form
                if movesFiles {
                    Text("edit.moveNote.label", bundle: .module)
                        .scaledFont(size: 10)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14)
                }
                if let err = saveError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                }
                saveButton
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    // MARK: - Form

    @ViewBuilder
    private var form: some View {
        VStack(spacing: 4) {
            formPicker("search.qualityProfile.button",
                       selection: Binding(
                           get: { selectedProfileId ?? qualityProfiles.first?.id ?? 0 },
                           set: { selectedProfileId = $0 }
                       ),
                       options: qualityProfiles.map { ($0.id, $0.name) })

            switch request.source {
            case .radarr, .whisparr:
                formPicker("edit.availability.button",
                           selection: $availability,
                           options: RadarrMinimumAvailability.allCases.map { ($0, $0.displayName) })
            case .sonarr:
                formPicker("search.seriesType.button",
                           selection: $seriesType,
                           options: SonarrSeriesType.allCases.map { ($0, $0.displayName) })
                formPicker("edit.monitorNewSeasons.button",
                           selection: $monitorNewItems,
                           options: [
                               ("all", String(localized: "search.all.button", bundle: .module)),
                               ("none", String(localized: "search.none.button", bundle: .module)),
                           ])
                formToggle("edit.seasonFolder.button", isOn: $seasonFolder)
            case .lidarr:
                if !metadataProfiles.isEmpty {
                    formPicker("search.metadataProfile.button",
                               selection: Binding(
                                   get: { selectedMetadataProfileId ?? metadataProfiles.first?.id ?? 0 },
                                   set: { selectedMetadataProfileId = $0 }
                               ),
                               options: metadataProfiles.map { ($0.id, $0.name) })
                }
                formPicker("edit.monitorNewAlbums.button",
                           selection: $monitorNewItems,
                           options: [
                               ("all", String(localized: "search.all.button", bundle: .module)),
                               ("new", String(localized: "edit.newItems.button", bundle: .module)),
                               ("none", String(localized: "search.none.button", bundle: .module)),
                           ])
            }

            formPicker("search.rootFolder.button",
                       selection: Binding(
                           get: { selectedRootFolder ?? rootFolders.first ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: rootFolders.map { ($0, $0) })
        }
        .padding(.horizontal, 14)
    }

    private var movesFiles: Bool {
        guard let original = originalRootFolder, let selected = selectedRootFolder else { return false }
        return normalizedRoot(selected) != normalizedRoot(original)
    }

    // MARK: - Save CTA

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            Group {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        if !storeManager.isPro {
                            Image(systemName: "lock.fill")
                        }
                        Image(systemName: "checkmark")
                            .scaledFont(size: 11, weight: .semibold)
                        Text("edit.save.button", bundle: .module)
                            .scaledFont(size: 12, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .disabled(saving || loading)
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    // MARK: - Data

    private var client: any ArrAPIClient {
        configStore.arrClient(for: request.source)
    }

    private func normalizedRoot(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func load() async {
        loading = true
        loadError = nil
        defer {
            loading = false
            onReady?()
        }

        let search = configStore.searchClient(for: request.source)
        do {
            async let q = search.fetchQualityProfiles()
            async let f = search.fetchRootFolders()
            (qualityProfiles, rootFolders) = try await (q, f)
            if request.source == .lidarr {
                metadataProfiles = try await search.fetchMetadataProfiles()
            }
            let record = try await client.read { $0.settings(entityID: request.entityId) }
            selectedProfileId = record.qualityProfileId
            selectedMetadataProfileId = record.metadataProfileId
            if let parsed = record.minimumAvailability.flatMap(RadarrMinimumAvailability.init(rawValue:)) { availability = parsed }
            if let parsed = record.seriesType.flatMap(SonarrSeriesType.init(rawValue:)) { seriesType = parsed }
            if let raw = record.monitorNewItems { monitorNewItems = raw }
            if let raw = record.seasonFolder { seasonFolder = raw }
            if let recordRoot = record.rootFolderPath, !recordRoot.isEmpty {
                if let match = rootFolders.first(where: { normalizedRoot($0) == normalizedRoot(recordRoot) }) {
                    selectedRootFolder = match
                } else {
                    // Outside every configured root (removed/renamed server-side): keep it
                    // selectable so an untouched save can't move the files.
                    rootFolders.insert(recordRoot, at: 0)
                    selectedRootFolder = recordRoot
                }
                originalRootFolder = selectedRootFolder
            }
        } catch {
            loadError = String(
                format: String(localized: "Couldn't load details: %@", bundle: .module),
                error.localizedDescription
            )
        }
    }

    private func save() async {
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        saving = true
        saveError = nil
        defer { saving = false }

        var settings = ArrRecordSettings(qualityProfileId: selectedProfileId, rootFolderPath: selectedRootFolder)
        switch request.source {
        case .radarr, .whisparr:
            settings.minimumAvailability = availability.rawValue
        case .sonarr:
            settings.seriesType = seriesType.rawValue
            settings.monitorNewItems = monitorNewItems
            settings.seasonFolder = seasonFolder
        case .lidarr:
            settings.metadataProfileId = selectedMetadataProfileId
            settings.monitorNewItems = monitorNewItems
        }

        do {
            try await client.run { $0.updateSettings(entityID: request.entityId, settings) }
            onBack()
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Form primitives (same chrome as SearchAddPanel)

    private func formPicker<T: Hashable>(_ label: LocalizedStringKey, selection: Binding<T>,
                                         options: [(T, String)]) -> some View {
        HStack {
            Text(label, bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(options, id: \.0) { val, name in
                    Button(name) { selection.wrappedValue = val }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(verbatim: options.first(where: { $0.0 == selection.wrappedValue })?.1
                         ?? options.first?.1 ?? "—")
                        .scaledFont(size: 11)
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(size: 9)
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    private func formToggle(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        ModalFormToggle(label: label, isOn: isOn)
    }
}

#if os(macOS)
/// `.sheet` doesn't render inside a `MenuBarExtra` popover, hence an overlay.
struct MediaEditModalOverlay: View {
    let request: MediaEditRequest
    let onDismiss: () -> Void

    /// Mounts invisible and appears once loaded; mid-load it grew from a
    /// spinner card and read as a two-step slide-in.
    @State private var ready = false

    var body: some View {
        // No entry/exit animation on purpose; the user didn't want movement here.
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.black.opacity(0.20))
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .ignoresSafeArea()

            // Same chrome as SearchAddPanel's sticky footer.
            MediaEditPanel(request: request, onBack: onDismiss, onReady: { ready = true })
                .background(
                    Rectangle()
                        .fill(.clear)
                        .glassEffect(.regular, in: .rect)
                        .overlay(alignment: .top) { Divider().opacity(0.4) }
                        .ignoresSafeArea(edges: .bottom)
                )
                .shadow(color: .black.opacity(0.25), radius: 14, y: -2)
        }
        .opacity(ready ? 1 : 0)
        .allowsHitTesting(ready)
        .accessibilityHidden(!ready)
    }
}
#endif
