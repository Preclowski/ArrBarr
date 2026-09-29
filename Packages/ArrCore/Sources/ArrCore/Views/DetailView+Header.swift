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
            headerActionsMenu
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        #else
        EmptyView()
        #endif
    }

    /// All header actions behind one "…" — separate glyphs left the title too little width.
    var headerActionsMenu: some View {
        DetailActionsMenu(actions: detailActions, state: $actionState,
                          feedback: searchRunning ? .sending : searchFeedback)
    }

    /// Lidarr edits the album's artist but deletes the album alone; both wait for the album to load.
    /// The slug falls back to the loaded record: a lookup opened from the library carries none.
    var detailActions: DetailActions {
        let slug = item.contentSlug ?? radarrDetail?.titleSlug ?? sonarrDetail?.titleSlug ?? lidarrAlbum?.foreignAlbumId
        var actions = DetailActions(webURL: arrWebURL(source: item.source, slug: slug, in: configStore))
        guard let entityId = item.entityId else { return actions }
        actions.history = HistoryTarget(source: item.source, scope: .record(entityId), title: navTitleString)
        actions.search = DetailActions.Search(
            isSending: searchFeedback.isSending || searchRunning,
            onAutomatic: { startAutomaticSearch() },
            onManual: manualTarget.map { target in { manualSearchTarget = target } })
        if item.source == .lidarr {
            if let artistId = lidarrAlbum?.artistId {
                actions.edit = MediaEditRequest(source: .lidarr, entityId: artistId)
                actions.editLabel = "detail.editArtist.button"
                actions.delete = MediaDeleteRequest(source: .lidarr, target: .album(id: entityId, artistId: artistId),
                                                    title: navTitleString)
            }
        } else {
            actions.edit = MediaEditRequest(source: item.source, entityId: entityId)
            actions.delete = MediaDeleteRequest(source: item.source, target: .record(entityId), title: navTitleString)
        }
        return actions
    }

    func handleDeleted() {
        Task { await viewModel.refresh() }
        onDeleted?()
        onBack()
    }
}
