import SwiftUI

/// What the detail header's pencil opens — the record being edited.
public struct MediaEditRequest: Identifiable, Hashable {
    let source: QueueItem.Source
    /// Arr record id — movie id (Radarr/Whisparr), series id (Sonarr),
    /// ARTIST id (Lidarr; albums have no editable profile of their own).
    let entityId: Int
    public var id: String { "\(source.rawValue)-edit-\(entityId)" }
}

/// True modal for editing an in-library movie / series / artist — quality
/// profile, availability / series type / metadata profile, root folder.
///
/// macOS hosts the card in `MediaEditModalOverlay` (scrim + bottom card, the
/// `ModalConfirmOverlay` pattern) so the detail view stays visible behind it;
/// iOS presents the same card as a native sheet. Neither is a navigation
/// push — the detail surface never moves.
struct MediaEditPanel: View {
    let request: MediaEditRequest
    let onBack: () -> Void
    /// Fired once `load()` settles (options + record fetched, or the demo /
    /// error path resolved). The macOS overlay keeps the whole modal
    /// invisible until then — showing it mid-load meant a short spinner card
    /// that grew when the pickers landed, which read as a 2-frame slide-in.
    var onReady: (() -> Void)? = nil

    @EnvironmentObject private var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared

    @State private var qualityProfiles: [QualityProfile] = []
    @State private var metadataProfiles: [MetadataProfile] = []
    @State private var rootFolders: [RootFolder] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var saving = false
    @State private var saveError: String?

    // Selections, seeded from the record's current values in `load()`.
    @State private var selectedProfileId: Int?
    @State private var selectedMetadataProfileId: Int?
    @State private var selectedRootFolder: String?
    @State private var availability: RadarrMinimumAvailability = .released
    @State private var seriesType: SonarrSeriesType = .standard
    /// `monitorNewItems` — whether freshly-announced seasons (Sonarr) /
    /// albums (Lidarr) get monitored automatically. Both arrs use the same
    /// record field; Sonarr's enum is "all" / "none", Lidarr adds "new".
    @State private var monitorNewItems = "all"
    @State private var seasonFolder = true
    /// Root folder the record lives in right now — a differing selection
    /// shows the "files will move on disk" note (the save then goes out
    /// with `moveFiles=true`, see `updateLibraryRecord`).
    @State private var originalRootFolder: String?

    var body: some View {
        // Same skeleton as SearchAddPanel's sticky footer — spacing 6, form
        // rows, then the glass CTA — so add and edit read as one form
        // language. Only the slim title/dismiss row on top is extra: a modal
        // needs an explicit close affordance.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("detail.edit.button", bundle: .module)
                    .scaledFont(size: 14, weight: .semibold)
                Spacer(minLength: 0)
                Button(action: onBack) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(Text("Cancel", bundle: .module))
            }
            .padding(.horizontal, 14)

            if loading {
                ProgressView()
                    .controlSize(.small)
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
        .task(id: request.id) { await load() }
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
                           get: { selectedRootFolder ?? rootFolders.first?.path ?? "" },
                           set: { selectedRootFolder = $0 }
                       ),
                       options: rootFolders.map { ($0.path, $0.path) })
        }
        .padding(.horizontal, 14)
    }

    /// True when the selected root folder differs from the record's current
    /// one — the save will relocate the files on disk.
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

    private var config: ServiceConfig {
        switch request.source {
        case .radarr: return configStore.radarr
        case .sonarr: return configStore.sonarr
        case .lidarr: return configStore.lidarr
        case .whisparr: return configStore.whisparr
        }
    }

    private var client: any ArrAPIClient {
        switch request.source {
        case .radarr: return RadarrClient(config: configStore.radarr)
        case .sonarr: return SonarrClient(config: configStore.sonarr)
        case .lidarr: return LidarrClient(config: configStore.lidarr)
        case .whisparr: return WhisparrClient(config: configStore.whisparr)
        }
    }

    /// The record's REST path — the same one the raw fetch and the PUT hit.
    private var recordPath: String {
        switch request.source {
        case .radarr, .whisparr: return "/movie/\(request.entityId)"
        case .sonarr: return "/series/\(request.entityId)"
        case .lidarr: return "/artist/\(request.entityId)"
        }
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

        let search = SearchClient(config: config, source: request.source)
        async let q = (try? search.fetchQualityProfiles()) ?? []
        async let f = (try? search.fetchRootFolders()) ?? []
        qualityProfiles = await q
        rootFolders = await f
        if request.source == .lidarr {
            metadataProfiles = (try? await search.fetchMetadataProfiles()) ?? []
        }

        // Demo mode has no raw record to read — seed from the first options
        // so the form is usable; the save no-ops server-side anyway.
        if DemoMode.isActive {
            selectedProfileId = qualityProfiles.first?.id
            selectedMetadataProfileId = metadataProfiles.first?.id
            selectedRootFolder = rootFolders.first?.path
            originalRootFolder = selectedRootFolder
            return
        }

        do {
            let record = try await client.getRawObject(recordPath)
            selectedProfileId = record["qualityProfileId"] as? Int
            selectedMetadataProfileId = record["metadataProfileId"] as? Int
            if let raw = record["minimumAvailability"] as? String,
               let parsed = RadarrMinimumAvailability(rawValue: raw) {
                availability = parsed
            }
            if let raw = record["seriesType"] as? String,
               let parsed = SonarrSeriesType(rawValue: raw) {
                seriesType = parsed
            }
            if let raw = record["monitorNewItems"] as? String {
                monitorNewItems = raw
            }
            if let raw = record["seasonFolder"] as? Bool {
                seasonFolder = raw
            }
            if let recordRoot = record["rootFolderPath"] as? String, !recordRoot.isEmpty {
                if let match = rootFolders.first(where: { normalizedRoot($0.path) == normalizedRoot(recordRoot) }) {
                    selectedRootFolder = match.path
                } else {
                    // The record sits outside every configured root (folder
                    // was removed / renamed server-side) — keep its actual
                    // location selectable so an untouched save can't move it.
                    rootFolders.insert(RootFolder(id: -1, path: recordRoot), at: 0)
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

        var fields: [String: Any] = [:]
        if let pid = selectedProfileId { fields["qualityProfileId"] = pid }
        if let root = selectedRootFolder { fields["rootFolderPath"] = root }
        switch request.source {
        case .radarr, .whisparr:
            fields["minimumAvailability"] = availability.rawValue
        case .sonarr:
            fields["seriesType"] = seriesType.rawValue
            fields["monitorNewItems"] = monitorNewItems
            fields["seasonFolder"] = seasonFolder
        case .lidarr:
            if let mid = selectedMetadataProfileId { fields["metadataProfileId"] = mid }
            fields["monitorNewItems"] = monitorNewItems
        }

        do {
            try await client.updateLibraryRecord(path: recordPath, fields: fields)
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
        HStack {
            Text(label, bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            Spacer()
            // `.labelsHidden()` strips the switch from the accessibility
            // tree too — restore a name so it doesn't announce as an
            // anonymous "off" (same fix as MCPSettingsPane's tool rows).
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(Text(label, bundle: .module))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }
}

#if os(macOS)
/// macOS host for the edit card: light scrim over the (still-visible) detail
/// surface + the card pinned to the bottom — the `ModalConfirmOverlay`
/// pattern, because `.sheet` doesn't render inside a `MenuBarExtra` popover.
struct MediaEditModalOverlay: View {
    let request: MediaEditRequest
    let onDismiss: () -> Void

    /// Render-first-show-later: the modal mounts invisible (and
    /// click-through), loads its options + record, and only then appears —
    /// fully formed, in one frame. Showing it mid-load produced a short
    /// spinner card that grew when the pickers landed, which read as a
    /// choppy two-step slide-in.
    @State private var ready = false

    var body: some View {
        // No entry/exit animation on purpose — the modal (and its scrim)
        // snaps in and out. Callers set `editRequest` without withAnimation;
        // a slide/fade here read as movement the user explicitly didn't want.
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.black.opacity(0.20))
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .ignoresSafeArea()

            // Edge-to-edge bottom surface with the EXACT chrome of
            // SearchAddPanel's sticky footer (thin material + top divider) —
            // the add form and the edit modal must read as the same surface.
            MediaEditPanel(request: request, onBack: onDismiss, onReady: { ready = true })
                .background(
                    Rectangle()
                        .fill(.thinMaterial)
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
