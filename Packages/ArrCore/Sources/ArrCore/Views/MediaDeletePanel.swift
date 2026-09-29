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

/// macOS hosts it in `MediaDeleteModalOverlay` because `.sheet` doesn't render in a MenuBarExtra popover;
/// iOS uses a native sheet. Both flags default off like the arr's, so nothing loads first.
struct MediaDeletePanel: View {
    let request: MediaDeleteRequest
    let onCancel: () -> Void
    /// The host closes the modal, and leaves the detail when its record went with it.
    let onDeleted: () -> Void

    @EnvironmentObject private var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared

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

    private var macCard: some View {
        // Same skeleton as the edit card: both live under the same glyph and must read as one surface.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(headingKey, bundle: .module)
                    .scaledFont(size: 14, weight: .semibold)
                Text(verbatim: request.title)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                PanelCloseButton(action: onCancel)
            }
            .padding(.horizontal, 14)

            if request.offersOptions {
                VStack(spacing: 4) {
                    ModalFormToggle(label: "delete.filesFromDisk.button", isOn: $deleteFiles)
                    ModalFormToggle(label: "delete.addExclusion.button", isOn: $addExclusion)
                }
                .padding(.horizontal, 14)
            } else {
                Text("delete.fileOnlyWarning.label", bundle: .module)
                    .scaledFont(size: 10)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
            }

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
                        Text(request.offersOptions ? "delete.confirm.button" : "detail.deleteFile.button", bundle: .module)
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
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.black.opacity(0.20))
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .ignoresSafeArea()

            MediaDeletePanel(request: request, onCancel: onDismiss, onDeleted: onDeleted)
                .background(
                    Rectangle()
                        .fill(.clear)
                        .glassEffect(.regular, in: .rect)
                        .overlay(alignment: .top) { Divider().opacity(0.4) }
                        .ignoresSafeArea(edges: .bottom)
                )
                .shadow(color: .black.opacity(0.25), radius: 14, y: -2)
        }
    }
}
#endif
