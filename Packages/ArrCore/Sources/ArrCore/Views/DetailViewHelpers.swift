import Foundation
import SwiftUI
import MediaKit

/// Pure helpers used by `DetailView`'s per-arr sections. Lifted out as free
/// functions so the per-arr `*Content` view-builders don't have to be members
/// of `DetailView` just to reach `configStore`. Each takes `(item, configStore)`
/// (plus per-call extras like an images array) and computes a stateless answer.

/// Poster auth key for the source's configured arr. Returns the api key for
/// whichever arr `item.source` points at, regardless of whether the poster
/// actually requires auth — callers gate on `item.posterRequiresAuth`.
func arrAPIKey(for item: QueueItem, in configStore: ConfigStore) -> String? {
    configStore.config(for: item.source).apiKey
}

/// Deep-link to the arr's web UI for this item, if we know a slug. Path
/// differs per arr — Sonarr uses `/series/`, Lidarr `/album/`, Radarr +
/// Whisparr both use `/movie/` (Whisparr is a Radarr fork).
func arrWebURL(for item: QueueItem, in configStore: ConfigStore) -> URL? {
    guard let slug = item.contentSlug else { return nil }
    let cfg = configStore.config(for: item.source)
    let path: String = switch item.source {
    case .radarr, .whisparr: "/movie/\(slug)"
    case .sonarr:            "/series/\(slug)"
    case .lidarr:            "/album/\(slug)"
    }
    return URL(string: cfg.baseURL)?.appendingPathComponent(path)
}

/// Resolve a poster URL from an arr's `images` array against its base URL.
/// Falls back to `item.posterURL` (set when the source had no images list)
/// is the caller's job — this only resolves the images side.
///
/// `mediaServerKeys` lets the connected media server's artwork win over the
/// arr's — callers that have the title's provider ids pass them, the rest get
/// the previous behaviour.
func arrPosterURL(images: [ArrImage]?, for item: QueueItem,
                  in configStore: ConfigStore,
                  mediaServerKeys: [MediaServerExternalKey] = []) -> URL? {
    let baseURL = configStore.config(for: item.source).baseURL
    return images?.posterURL(baseURL: baseURL, coverTypes: ["poster", "cover"],
                             mediaServerKeys: mediaServerKeys).0
}

// MARK: - Modal form primitives

/// One switch row in a modal card (edit / delete) — the same chrome the
/// pickers beside it use, so a card of mixed controls reads as one form.
struct ModalFormToggle: View {
    let label: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label, bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            Spacer()
            // `.labelsHidden()` strips the switch from the accessibility
            // tree too — restore a name so it doesn't announce as an
            // anonymous "off" (same fix as MCPSettingsPane's tool rows).
            Toggle("", isOn: $isOn)
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

// MARK: - Row search context menu

/// Right-click (macOS) / long-press (iOS) twin of `HeaderSearchMenu`: the same
/// Automatic / Manual choice, on the row that owns it, so a season or episode
/// can be searched without first drilling into its screen for the header glyph.
///
/// The sweep choreography lives here rather than in each row — the row only
/// owns the two flags so it can put the spinner / checkmark wherever its own
/// layout has room.
struct RowSearchContextMenu: ViewModifier {
    @Binding var inFlight: Bool
    @Binding var didQueue: Bool
    let onAutomatic: () async -> Void
    let onManual: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                guard !inFlight else { return }
                Task {
                    inFlight = true
                    await onAutomatic()
                    inFlight = false
                    didQueue = true
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    didQueue = false
                }
            } label: {
                Label { Text("Automatic search", bundle: .module) } icon: { Image(systemName: "bolt.fill") }
            }
            .disabled(inFlight)
            Button(action: onManual) {
                Label { Text("Manual search", bundle: .module) } icon: { Image(systemName: "list.bullet") }
            }
        }
    }
}

/// `RowSearchContextMenu` for rows whose host may or may not own a search path
/// — with either closure missing there is no menu at all, rather than one with
/// a dead item in it.
struct OptionalRowSearchMenu: ViewModifier {
    @Binding var inFlight: Bool
    @Binding var didQueue: Bool
    let onAutomatic: (() async -> Void)?
    let onManual: (() -> Void)?

    func body(content: Content) -> some View {
        if let onAutomatic, let onManual {
            content.rowSearchContextMenu(inFlight: $inFlight, didQueue: $didQueue,
                                         onAutomatic: onAutomatic, onManual: onManual)
        } else {
            content
        }
    }
}

extension View {
    /// Attaches the Automatic / Manual search menu to a list row. Both flags are
    /// the row's own state; it renders them (spinner, then a brief checkmark).
    func rowSearchContextMenu(
        inFlight: Binding<Bool>,
        didQueue: Binding<Bool>,
        onAutomatic: @escaping () async -> Void,
        onManual: @escaping () -> Void
    ) -> some View {
        modifier(RowSearchContextMenu(inFlight: inFlight, didQueue: didQueue,
                                      onAutomatic: onAutomatic, onManual: onManual))
    }
}

// MARK: - Header search menu

/// Toolbar/header search control: a bare magnifier glyph (sized to sit in
/// the `[search] [bookmark] [safari] [trash]` cluster) whose tap opens the
/// native Automatic / Manual menu — the same choice the bottom "Search" CTA
/// used to offer before it moved up here. Carries the sweep states inline:
/// spinner while a search runs, a brief checkmark right after queueing one.
struct HeaderSearchMenu: View {
    let inFlight: Bool
    let didQueue: Bool
    let onAutomatic: () -> Void
    let onManual: () -> Void

    var body: some View {
        Menu {
            Button(action: onAutomatic) {
                Label { Text("Automatic search", bundle: .module) } icon: { Image(systemName: "bolt.fill") }
            }
            Button(action: onManual) {
                Label { Text("Manual search", bundle: .module) } icon: { Image(systemName: "list.bullet") }
            }
        } label: {
            Group {
                if inFlight {
                    ProgressView().controlSize(.small)
                } else if didQueue {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "magnifyingglass")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(inFlight)
        .help(Text("Search", bundle: .module))
        .accessibilityLabel(inFlight
                            ? Text("detail.searchingForRelease.label", bundle: .module)
                            : Text("Search", bundle: .module))
    }
}
