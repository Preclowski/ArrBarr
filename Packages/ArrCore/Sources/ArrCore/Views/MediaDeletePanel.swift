import SwiftUI

struct MediaDeleteRequest: Identifiable, Hashable {
    enum Target: Hashable {
        /// The library record: a movie, series or Lidarr artist.
        case record(Int)
        /// A Lidarr album; its artist stays.
        case album(id: Int, artistId: Int)
        /// The file on disk only; the episode stays in the library.
        case episodeFile(id: Int, seriesId: Int)
    }

    let source: QueueItem.Source
    let target: Target
    let title: String
    var id: String { "\(source.rawValue)-delete-\(target)" }

    /// A file has no library side to spare, so nothing to choose.
    var offersOptions: Bool {
        if case .episodeFile = target { return false }
        return true
    }
}

/// macOS hosts it as an in-panel alert (`MediaDeleteModalOverlay`): `.sheet` doesn't render in a MenuBarExtra popover;
/// iOS uses a native sheet. Both flags default off like the arr's, so nothing loads first.
struct MediaDeletePanel: View {
    let request: MediaDeleteRequest
    let onCancel: () -> Void
    /// The host closes the modal, and leaves the detail when its record went with it.
    let onDeleted: () -> Void

    @Environment(ConfigStore.self) private var configStore
    private var storeManager: StoreManager { .shared }

    @State private var deleteFiles = false
    @State private var addExclusion = false
    @State private var deleting = false
    @State private var deleteError: String?

    #if os(iOS)
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
                    if request.offersOptions {
                        Toggle(isOn: $deleteFiles) { Text("delete.filesFromDisk.button", bundle: .module) }
                        Toggle(isOn: $addExclusion) { Text("delete.addExclusion.button", bundle: .module) }
                    } else {
                        Text("delete.fileOnlyWarning.label", bundle: .module)
                    }
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
            .navigationTitle(Text(headingKey, bundle: .module))
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
                                Text(headingKey, bundle: .module)
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
        let chrome: CGFloat = 150
        let extras = (deleteFiles ? formRowHeight : 0) + (deleteError == nil ? 0 : formRowHeight)
        return (request.offersOptions ? 2 : 1) * formRowHeight + chrome + extras
    }
    #endif

    // MARK: - macOS

    #if os(macOS)
    /// The alert's content; `MediaDeleteModalOverlay` gives it the alert chrome.
    private var macCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("delete.alert.title \(request.title)", bundle: .module)
                    .scaledFont(size: 13, weight: .bold)
                    .fixedSize(horizontal: false, vertical: true)
                if !request.offersOptions {
                    Text("delete.fileOnlyWarning.label", bundle: .module)
                        .scaledFont(size: 12)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if request.offersOptions {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $deleteFiles) {
                        Text("delete.filesFromDisk.button", bundle: .module).scaledFont(size: 12)
                    }
                    Toggle(isOn: $addExclusion) {
                        Text("delete.addExclusion.button", bundle: .module).scaledFont(size: 12)
                    }
                    if deleteFiles {
                        Text("delete.filesWarning.label", bundle: .module)
                            .scaledFont(size: 11)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }
            if let err = deleteError {
                Text(err)
                    .scaledFont(size: 11)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                AlertAnswerButton(foreground: .primary, background: Color.primary.opacity(0.1), action: onCancel) {
                    Text("common.cancel.button", bundle: .module)
                }
                .keyboardShortcut(.escape, modifiers: [])
                AlertAnswerButton(foreground: .red, background: Color.red.opacity(0.22),
                                  action: { Task { await performDelete() } }) {
                    if deleting {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 4) {
                            if !storeManager.isPro { Image(systemName: "lock.fill") }
                            Text(headingKey, bundle: .module)
                        }
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(deleting)
            }
        }
    }

    #endif

    private var headingKey: LocalizedStringKey {
        request.offersOptions ? "detail.delete.button" : "detail.deleteFile.button"
    }

    // MARK: - Data

    private func performDelete() async {
        // Changing what is in the library is the Control side of the app.
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        deleting = true
        deleteError = nil
        defer { deleting = false }
        do {
            switch request.target {
            case let .record(id):
                try await configStore.arrClient(for: request.source)
                    .deleteLibraryRecord(entityId: id, deleteFiles: deleteFiles, addImportExclusion: addExclusion)
            case let .album(id, artistId):
                try await configStore.lidarrClient
                    .deleteAlbum(albumId: id, artistId: artistId, deleteFiles: deleteFiles, addImportListExclusion: addExclusion)
            case let .episodeFile(id, seriesId):
                try await configStore.sonarrClient.deleteEpisodeFile(id: id, seriesId: seriesId)
            }
            onDeleted()
        } catch {
            // The arr puts the real reason in the response body, not the status.
            deleteError = error.localizedDescription
        }
    }
}

#if os(macOS)
/// Unlike the edit modal it has nothing to fetch first.
struct MediaDeleteModalOverlay: View {
    let request: MediaDeleteRequest
    let onDismiss: () -> Void
    let onDeleted: () -> Void

    var body: some View {
        AlertCard(onCancel: onDismiss) {
            MediaDeletePanel(request: request, onCancel: onDismiss, onDeleted: onDeleted)
        }
    }
}
#endif
