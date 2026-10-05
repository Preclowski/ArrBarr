import SwiftUI
#if os(macOS)
import AppKit
#endif

/// What a detail's "…" menu offers. Each detail fills in what its subject supports; the menu keeps
/// one order everywhere and `detailActionsHost` presents what it opens.
struct DetailActions {
    struct Search {
        var isSending: Bool
        var onAutomatic: (() -> Void)?
        var onManual: (() -> Void)?
    }

    var edit: MediaEditRequest?
    var editLabel: LocalizedStringKey = "detail.edit.button"
    var history: HistoryTarget?
    var search: Search?
    var webURL: URL?
    var delete: MediaDeleteRequest?
    var deleteLabel: LocalizedStringKey = "detail.delete.button"

    var isEmpty: Bool { edit == nil && history == nil && search == nil && webURL == nil && delete == nil }
}

struct HistoryTarget: Hashable {
    let source: QueueItem.Source
    let scope: HistoryScope
    let title: String
}

/// What the menu opened. Owned by the detail, so its `detailActionsHost` can present it.
struct DetailActionState {
    var edit: MediaEditRequest?
    var delete: MediaDeleteRequest?
    var history: HistoryTarget?
}

/// The "…" in a detail's header; while a search is in flight the glyph shows its progress.
struct DetailActionsMenu: View {
    let actions: DetailActions
    @Binding var state: DetailActionState
    var feedback: SearchFeedback = .idle

    var body: some View {
        if !actions.isEmpty {
            TrailingMenu { items } label: { glyph }
                #if os(macOS)
                .help(Text("common.moreActions.button", bundle: .module))
                #endif
                .accessibilityLabel(Text("common.moreActions.button", bundle: .module))
                .accessibilityValue(feedback.isSending ? Text("detail.searchingForRelease.label", bundle: .module) : Text(verbatim: ""))
        }
    }

    @ViewBuilder
    private var glyph: some View {
        #if os(macOS)
        if feedback == .idle {
            HeaderGlyph(systemName: "ellipsis")
        } else {
            SearchFeedbackIcon(feedback: feedback, size: 13)
                .frame(width: 22, height: 22)
        }
        #else
        if feedback == .idle {
            Image(systemName: "ellipsis")
        } else {
            SearchFeedbackIcon(feedback: feedback, size: 13)
        }
        #endif
    }

    /// One run in the order the row menus share; search leads, as the glyph shows its progress.
    @ViewBuilder
    private var items: some View {
        if let search = actions.search {
            Group {
                if let onAutomatic = search.onAutomatic {
                    Button(action: onAutomatic) { DetailMenuLabel.automaticSearch }
                }
                if let onManual = search.onManual {
                    Button(action: onManual) { DetailMenuLabel.manualSearch }
                }
            }
            .disabled(search.isSending)
        }
        if let edit = actions.edit {
            Button { state.edit = edit } label: { DetailMenuLabel.edit(actions.editLabel) }
        }
        if let history = actions.history {
            Button { state.history = history } label: { DetailMenuLabel.history }
        }
        if let url = actions.webURL {
            Button { PlatformURLOpener.open(url) } label: { DetailMenuLabel.openInBrowser }
        }
        // The only divider: a mis-click next to "open in browser" would cost a library record.
        if let delete = actions.delete {
            Section {
                Button(role: .destructive) { state.delete = delete } label: {
                    Label { Text(actions.deleteLabel, bundle: .module) } icon: { Image(systemName: "trash") }
                }
            }
        }
    }
}

/// Labels the "…" and the row menus share, so an entry reads the same in both. Literal `Text` keys,
/// so Xcode's extraction still sees them.
enum DetailMenuLabel {
    static var automaticSearch: some View {
        Label { Text("Automatic search", bundle: .module) } icon: { Image(systemName: "bolt.fill") }
    }
    static var manualSearch: some View {
        Label { Text("Manual search", bundle: .module) } icon: { Image(systemName: "list.bullet") }
    }
    static var history: some View {
        Label { Text("detail.showHistory.button", bundle: .module) } icon: { Image(systemName: "clock.arrow.circlepath") }
    }
    static var openInBrowser: some View {
        Label { Text("detail.openInBrowser.button", bundle: .module) } icon: { Image(systemName: "safari") }
    }
    static func edit(_ key: LocalizedStringKey) -> some View {
        Label { Text(key, bundle: .module) } icon: { Image(systemName: "pencil") }
    }
}

// MARK: - Row menus

/// What a row's context menu asks the detail it opens to go straight into. The detail carries it out
/// once loaded: manual search frames against the file on disk, a Lidarr album edits its artist.
public enum DetailIntent: Sendable {
    case automaticSearch, manualSearch, edit, history

    var isSearch: Bool { self == .automaticSearch || self == .manualSearch }

    /// Mirrors each detail's `detailActions`, so a row never offers what its detail can't open.
    static func supported(by item: QueueItem) -> [DetailIntent] {
        guard item.entityId != nil else { return [] }
        if item.opensEpisodeDetail { return [.automaticSearch, .manualSearch, .history] }
        // A series searches per season, an artist has no manual search.
        let manual = item.source != .sonarr && !item.isLidarrArtistLookup
        return [.automaticSearch] + (manual ? [.manualSearch] : []) + [.edit, .history]
    }
}

extension QueueItem {
    /// The popover opens a Sonarr episode row (a pack has no episode number) on the episode,
    /// skipping the series chrome; iOS opens the series.
    var opensEpisodeDetail: Bool {
        #if os(macOS)
        source == .sonarr && (episodeNumber ?? 0) > 0 && entityId != nil
        #else
        false
        #endif
    }
}

/// A row's twin of its detail's "…", minus delete, which stays in the detail. Each entry opens the
/// detail, which then runs the search or pushes or presents the view.
struct DetailEntryMenuItems: View {
    let target: QueueItem
    let webURL: URL?
    /// False for an episode that hasn't aired: its detail offers no search either.
    var searchable = true

    var body: some View {
        ForEach(DetailIntent.supported(by: target).filter { searchable || !$0.isSearch }, id: \.self) { intent in
            Button { DetailRequest.post(target, intent: intent) } label: {
                switch intent {
                case .automaticSearch: DetailMenuLabel.automaticSearch
                case .manualSearch: DetailMenuLabel.manualSearch
                case .edit: DetailMenuLabel.edit(editLabel)
                case .history: DetailMenuLabel.history
                }
            }
        }
        if let webURL {
            Button { PlatformURLOpener.open(webURL) } label: { DetailMenuLabel.openInBrowser }
        }
    }

    /// An album's detail edits its artist and says so.
    private var editLabel: LocalizedStringKey {
        target.source == .lidarr && !target.isLidarrArtistLookup ? "detail.editArtist.button" : "detail.edit.button"
    }
}

extension DetailActions {
    /// Opens what a row menu asked for, if this subject offers it.
    func carryOut(_ intent: DetailIntent, state: Binding<DetailActionState>) {
        switch intent {
        case .automaticSearch: search?.onAutomatic?()
        case .manualSearch: search?.onManual?()
        case .edit: state.wrappedValue.edit = edit
        case .history: state.wrappedValue.history = history
        }
    }
}

extension View {
    /// Hands the detail for `itemID` the intent a row menu staged, once `ready` (loaded).
    func onDetailIntent(for itemID: String?, ready: Bool,
                        perform: @escaping (DetailIntent) -> Void) -> some View {
        onChange(of: ready, initial: true) { _, ready in
            guard ready, let itemID, let intent = DetailIntents.take(for: itemID) else { return }
            perform(intent)
        }
    }
}

extension View {
    /// Presents what a `DetailActionsMenu` opened: edit and delete as a bottom card on macOS
    /// (`.sheet` doesn't render in a MenuBarExtra popover), sheets on iOS; history as a push.
    func detailActionsHost(_ state: Binding<DetailActionState>,
                           onDeleted: @escaping (MediaDeleteRequest) -> Void) -> some View {
        modifier(DetailActionsHost(state: state, onDeleted: onDeleted))
    }
}

private struct DetailActionsHost: ViewModifier {
    @Binding var state: DetailActionState
    let onDeleted: (MediaDeleteRequest) -> Void

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .overlay {
                if let request = state.edit {
                    MediaEditModalOverlay(request: request, onDismiss: { state.edit = nil })
                }
                if let request = state.delete {
                    MediaDeleteModalOverlay(request: request, onDismiss: { state.delete = nil },
                                            onDeleted: { deleted(request) })
                }
            }
            #else
            .sheet(item: $state.edit) { request in
                MediaEditPanel(request: request, onBack: { state.edit = nil })
            }
            .sheet(item: $state.delete) { request in
                MediaDeletePanel(request: request, onCancel: { state.delete = nil },
                                 onDeleted: { deleted(request) })
            }
            #endif
            // `isPresented`, not `item`: nested details in one stack would share the item type,
            // and SwiftUI honours only the root-most destination per type.
            .navigationDestination(isPresented: Binding(get: { state.history != nil },
                                                        set: { if !$0 { state.history = nil } })) {
                if let target = state.history {
                    HistoryView(source: target.source, scope: target.scope, title: target.title,
                                viewModel: QueueViewModel.shared, onClose: { state.history = nil })
                }
            }
    }

    /// The detail usually closes with the record, so the toast is what confirms it.
    private func deleted(_ request: MediaDeleteRequest) {
        state.delete = nil
        ToastCenter.shared.show(Toast(tone: .success, symbol: "checkmark.circle.fill",
                                      title: "toast.removed.title", detail: request.title))
        onDeleted(request)
    }
}

/// A menu on a header's trailing edge. macOS pops it from the label's trailing edge so it opens into
/// the popover: SwiftUI's `Menu` always hangs off the leading edge, past the popover's side.
struct TrailingMenu<Items: View, MenuLabel: View>: View {
    @ViewBuilder var items: () -> Items
    @ViewBuilder var label: () -> MenuLabel

    #if os(macOS)
    @Environment(\.locale) private var locale
    @State private var anchor = MenuAnchor()
    #endif

    var body: some View {
        #if os(macOS)
        Button {
            // The menu is its own hierarchy, so the live language switch has to be handed over.
            anchor.popUp(NSHostingMenu(rootView: Group { items() }.environment(\.locale, locale)))
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        #else
        Menu { items() } label: { label() }
        #endif
    }
}

/// A header's trailing glyph: the size and weight every detail header uses. Full-strength, since
/// the popover's vibrancy dims a secondary glyph to near-invisible.
struct HeaderGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .scaledFont(size: 14, weight: .medium)
            .foregroundStyle(.primary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

#if os(macOS)
@MainActor
private final class MenuAnchor {
    weak var view: NSView?

    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let origin = NSPoint(x: view.bounds.maxX - menu.size.width, y: view.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: origin, in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
#endif
