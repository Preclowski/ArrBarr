import SwiftUI

/// What the detail header's pencil menu deletes — the record being removed
/// from the arr's library.
public struct MediaDeleteRequest: Identifiable, Hashable {
    let source: QueueItem.Source
    /// Arr record id — movie id (Radarr/Whisparr), series id (Sonarr),
    /// ARTIST id (Lidarr; an album is deleted from its artist in the arr).
    let entityId: Int
    /// Shown in the modal so the user confirms against a name, not an id.
    let title: String
    public var id: String { "\(source.rawValue)-delete-\(entityId)" }
}

/// True modal for removing an in-library movie / series / artist, with the two
/// choices the arrs themselves offer: delete the files on disk too, and add an
/// import-list exclusion so a list doesn't put it straight back.
///
/// Same presentation split as `MediaEditPanel` — macOS hosts the card in
/// `MediaDeleteModalOverlay` (scrim + bottom card, because `.sheet` doesn't
/// render inside a MenuBarExtra popover), iOS presents the same choices as a
/// native sheet. Nothing loads first: both flags default to the arr's own
/// defaults (off), so the modal can appear in one frame.
struct MediaDeletePanel: View {
    let request: MediaDeleteRequest
    let onCancel: () -> Void
    /// The arr accepted the delete — the record no longer exists, so the host
    /// closes the modal AND leaves the detail surface behind it.
    let onDeleted: () -> Void

    @EnvironmentObject private var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared

    @State private var deleteFiles = false
    @State private var addExclusion = false
    @State private var deleting = false
    @State private var deleteError: String?

    #if os(iOS)
    /// One Form row at the user's text size — the sheet is sized from this.
    @ScaledMetric(relativeTo: .body) private var formRowHeight: CGFloat = 44
    #endif

    var body: some View {
        #if os(iOS)
        iosForm
        #else
        macCard
        #endif
    }

    // MARK: - iOS

    #if os(iOS)
    private var iosForm: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $deleteFiles) { Text("delete.filesFromDisk.button", bundle: .module) }
                    Toggle(isOn: $addExclusion) { Text("delete.addExclusion.button", bundle: .module) }
                } header: {
                    Text(verbatim: request.title)
                }
                if deleteFiles {
                    Section {
                        Label { Text("delete.filesWarning.label", bundle: .module) }
                        icon: { Image(systemName: "exclamationmark.triangle.fill") }
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
                if let err = deleteError {
                    Section { Text(err).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(Text("detail.delete.button", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.height(fittedSheetHeight), .large])
            .presentationDragIndicator(.visible)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onCancel) { Text("common.cancel.button", bundle: .module) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        Task { await performDelete() }
                    } label: {
                        if deleting {
                            ProgressView()
                        } else {
                            HStack(spacing: 4) {
                                if !storeManager.isPro { Image(systemName: "lock.fill") }
                                Text("detail.delete.button", bundle: .module)
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .tint(.red)
                    .disabled(deleting)
                }
            }
        }
    }

    private var fittedSheetHeight: CGFloat {
        // Nav bar + the grouped section's own insets + grabber, then a row per
        // switch and one more for each conditional section.
        let chrome: CGFloat = 150
        let extras = (deleteFiles ? formRowHeight : 0) + (deleteError == nil ? 0 : formRowHeight)
        return 2 * formRowHeight + chrome + extras
    }
    #endif

    // MARK: - macOS

    private var macCard: some View {
        // Same skeleton as the edit card — title row, form rows, CTA — because
        // the two live under the same glyph and must read as one surface.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("detail.delete.button", bundle: .module)
                    .scaledFont(size: 14, weight: .semibold)
                Text(verbatim: request.title)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(action: onCancel) {
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

            VStack(spacing: 4) {
                ModalFormToggle(label: "delete.filesFromDisk.button", isOn: $deleteFiles)
                ModalFormToggle(label: "delete.addExclusion.button", isOn: $addExclusion)
            }
            .padding(.horizontal, 14)

            // Only while the files switch is on — the same place, colour and
            // restraint as the edit card's "files will move" note.
            if deleteFiles {
                Text("delete.filesWarning.label", bundle: .module)
                    .scaledFont(size: 10)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
            }
            if let err = deleteError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
            }
            deleteButton
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var deleteButton: some View {
        Button {
            Task { await performDelete() }
        } label: {
            Group {
                if deleting {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        if !storeManager.isPro {
                            Image(systemName: "lock.fill")
                        }
                        Image(systemName: "trash")
                            .scaledFont(size: 11, weight: .semibold)
                        Text("delete.confirm.button", bundle: .module)
                            .scaledFont(size: 12, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .tint(.red)
        .disabled(deleting)
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    // MARK: - Data

    private var client: any ArrAPIClient {
        switch request.source {
        case .radarr: return RadarrClient(config: configStore.radarr)
        case .sonarr: return SonarrClient(config: configStore.sonarr)
        case .lidarr: return LidarrClient(config: configStore.lidarr)
        case .whisparr: return WhisparrClient(config: configStore.whisparr)
        }
    }

    /// The record's REST path — the same one the edit panel reads and writes.
    private var recordPath: String {
        switch request.source {
        case .radarr, .whisparr: return "/movie/\(request.entityId)"
        case .sonarr: return "/series/\(request.entityId)"
        case .lidarr: return "/artist/\(request.entityId)"
        }
    }

    private func performDelete() async {
        // Same gate as the edit panel: changing what is in the library is the
        // Control side of the app.
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        deleting = true
        deleteError = nil
        defer { deleting = false }
        do {
            try await client.deleteLibraryRecord(path: recordPath,
                                                 deleteFiles: deleteFiles,
                                                 addImportExclusion: addExclusion)
            onDeleted()
        } catch {
            // The arr puts the real reason in the response body, not the status.
            deleteError = error.userFacingMessage
        }
    }
}

#if os(macOS)
/// macOS host for the delete card — the `MediaEditModalOverlay` twin. Appears
/// straight away: unlike the edit modal it has nothing to fetch first.
struct MediaDeleteModalOverlay: View {
    let request: MediaDeleteRequest
    let onDismiss: () -> Void
    let onDeleted: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.black.opacity(0.20))
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .ignoresSafeArea()

            MediaDeletePanel(request: request, onCancel: onDismiss, onDeleted: onDeleted)
                .background(
                    Rectangle()
                        .fill(.thinMaterial)
                        .overlay(alignment: .top) { Divider().opacity(0.4) }
                        .ignoresSafeArea(edges: .bottom)
                )
                .shadow(color: .black.opacity(0.25), radius: 14, y: -2)
        }
    }
}
#endif
