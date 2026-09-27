import Foundation
import SwiftUI
import MediaKit

/// Callers gate on `item.posterRequiresAuth`.
func arrAPIKey(for item: QueueItem, in configStore: ConfigStore) -> String? {
    configStore.config(for: item.source).apiKey
}

/// Whisparr is a Radarr fork, so it shares `/movie/`.
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

/// Falling back to `item.posterURL` is the caller's job. `mediaServerKeys`
/// lets the media server's artwork win.
func arrPosterURL(images: [ArrImage]?, for item: QueueItem,
                  in configStore: ConfigStore,
                  mediaServerKeys: [MediaServerExternalKey] = []) -> URL? {
    let baseURL = configStore.config(for: item.source).baseURL
    return images?.posterURL(baseURL: baseURL, coverTypes: ["poster", "cover"],
                             mediaServerKeys: mediaServerKeys).0
}

// MARK: - Modal form primitives

struct ModalFormToggle: View {
    let label: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label, bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            Spacer()
            // `.labelsHidden()` also strips the accessibility name.
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

/// Right-click / long-press twin of `HeaderSearchMenu`, so a row can be searched in place.
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

/// With either closure missing there is no menu, rather than a dead item.
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
