import SwiftUI

extension DetailView {
    // MARK: - Header (floating glass back + source info)

    @ViewBuilder
    var header: some View {
        // Self-drawn on both macOS surfaces: the detached NSWindow has no native chevron and the
        // popover's is hidden in `body`.
        #if os(macOS)
        HStack(spacing: 6) {
            FloatingBackButton(action: onBack)
                .keyboardShortcut(.cancelAction)
            Text(navTitleString)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            headerSearchMenu
            Menu {
                if let target = editTarget {
                    Button { editRequest = target } label: {
                        Label { Text("detail.edit.button", bundle: .module) } icon: { Image(systemName: "pencil") }
                    }
                }
                if item.entityId != nil {
                    Button { historyShown = true } label: {
                        Label { Text("detail.showHistory.button", bundle: .module) } icon: { Image(systemName: "clock.arrow.circlepath") }
                    }
                }
                if let url = arrWebURL(for: item, in: configStore) {
                    Button { PlatformURLOpener.open(url) } label: {
                        Label { Text("detail.openInBrowser.button", bundle: .module) } icon: { Image(systemName: "safari") }
                    }
                }
                // Last, own section: a mis-click next to "open in browser" would cost a library record.
                if let target = deleteTarget {
                    Section {
                        Button(role: .destructive) { deleteRequest = target } label: {
                            Label { Text("detail.delete.button", bundle: .module) } icon: { Image(systemName: "trash") }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(Text("common.moreActions.button", bundle: .module))
            .accessibilityLabel(Text("common.moreActions.button", bundle: .module))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        #else
        EmptyView()
        #endif
    }

    /// Nil for Lidarr albums — the editable entity is the artist, edited in `LidarrArtistView`.
    private var editTarget: MediaEditRequest? {
        guard item.source != .lidarr, let entityId = item.entityId else { return nil }
        return MediaEditRequest(source: item.source, entityId: entityId)
    }

    /// Lidarr excluded: the deletable record is the artist, handled in `LidarrArtistView`.
    private var deleteTarget: MediaDeleteRequest? {
        guard item.source != .lidarr, let entityId = item.entityId else { return nil }
        return MediaDeleteRequest(source: item.source, entityId: entityId, title: navTitleString)
    }

    func handleDeleted() {
        deleteRequest = nil
        Task { await viewModel.refresh() }
        onBack()
    }

    #if os(iOS)
    /// All header actions behind one "..." — separate glyphs left the title too little width.
    var headerActionsMenu: some View {
        Menu {
            if let target = editTarget {
                Button { editRequest = target } label: {
                    Label { Text("detail.edit.button", bundle: .module) } icon: { Image(systemName: "pencil") }
                }
            }
            if item.entityId != nil {
                Button { historyShown = true } label: {
                    Label { Text("detail.showHistory.button", bundle: .module) } icon: { Image(systemName: "clock.arrow.circlepath") }
                }
            }
            if manualTarget != nil {
                Section {
                    Button { startAutomaticSearch() } label: {
                        Label { Text("Automatic search", bundle: .module) } icon: { Image(systemName: "bolt.fill") }
                    }
                    .disabled(searchFeedback.isSending || searchRunning)
                    Button { manualSearchTarget = manualTarget } label: {
                        Label { Text("Manual search", bundle: .module) } icon: { Image(systemName: "list.bullet") }
                    }
                    .disabled(searchFeedback.isSending || searchRunning)
                }
            }
            if let url = arrWebURL(for: item, in: configStore) {
                Button { PlatformURLOpener.open(url) } label: {
                    Label { Text("detail.openInBrowser.button", bundle: .module) } icon: { Image(systemName: "safari") }
                }
            }
            // Last, own section: a mis-tap next to "open in browser" would cost a library record.
            if let target = deleteTarget {
                Section {
                    Button(role: .destructive) { deleteRequest = target } label: {
                        Label { Text("detail.delete.button", bundle: .module) } icon: { Image(systemName: "trash") }
                    }
                }
            }
        } label: {
            if searchFeedback.isSending || searchRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "ellipsis")
            }
        }
        .accessibilityLabel(Text("common.moreActions.button", bundle: .module))
    }
    #endif

    @ViewBuilder
    private var headerSearchMenu: some View {
        if let target = manualTarget {
            HeaderSearchMenu(
                feedback: searchRunning ? .sending : searchFeedback,
                onAutomatic: { startAutomaticSearch() },
                onManual: { manualSearchTarget = target }
            )
        }
    }
}
