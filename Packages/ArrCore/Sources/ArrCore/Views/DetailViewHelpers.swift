import Foundation
import SwiftUI
import os
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

// MARK: - Search feedback

/// A search button's outcome. The arr only confirms it accepted the command, so `queued` is as far as it goes;
/// `failed` carries the reason the command was refused or never arrived.
enum SearchFeedback: Equatable {
    case idle, sending, queued, failed(String)

    var isSending: Bool { self == .sending }

    private static let log = Logger(category: "Search")

    /// Sends `action` once at a time, then shows the outcome briefly.
    @MainActor
    static func run(_ feedback: Binding<SearchFeedback>, _ action: @escaping () async throws -> Void) {
        guard !feedback.wrappedValue.isSending else { return }
        feedback.wrappedValue = .sending
        Task {
            let shown: Duration
            do {
                try await action()
                feedback.wrappedValue = .queued
                shown = .seconds(1.6)
            } catch {
                log.error("search command failed: \(error.localizedDescription, privacy: .public)")
                feedback.wrappedValue = .failed(error.userFacingMessage)
                shown = .seconds(4)
            }
            try? await Task.sleep(for: shown)
            feedback.wrappedValue = .idle
        }
    }
}

/// Spinner, checkmark or warning in a row's trailing slot; nothing while idle.
struct SearchFeedbackIcon: View {
    let feedback: SearchFeedback
    var size: CGFloat = 10

    var body: some View {
        switch feedback {
        case .idle:
            EmptyView()
        case .sending:
            ProgressView().controlSize(.small)
        case .queued:
            Image(systemName: "checkmark")
                .scaledFont(size: size, weight: .semibold)
                .foregroundStyle(.secondary)
        case let .failed(reason):
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: size, weight: .semibold)
                .foregroundStyle(.orange)
                .help(Text(verbatim: reason))
                .accessibilityLabel(Text(verbatim: reason))
        }
    }
}

// MARK: - Row search context menu

/// Right-click / long-press twin of `HeaderSearchMenu`, so a row can be searched in place.
struct RowSearchContextMenu: ViewModifier {
    @Binding var feedback: SearchFeedback
    let onAutomatic: () async throws -> Void
    let onManual: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                SearchFeedback.run($feedback, onAutomatic)
            } label: {
                Label { Text("Automatic search", bundle: .module) } icon: { Image(systemName: "bolt.fill") }
            }
            .disabled(feedback.isSending)
            Button(action: onManual) {
                Label { Text("Manual search", bundle: .module) } icon: { Image(systemName: "list.bullet") }
            }
        }
    }
}

/// With either closure missing there is no menu, rather than a dead item.
struct OptionalRowSearchMenu: ViewModifier {
    @Binding var feedback: SearchFeedback
    let onAutomatic: (() async throws -> Void)?
    let onManual: (() -> Void)?

    func body(content: Content) -> some View {
        if let onAutomatic, let onManual {
            content.modifier(RowSearchContextMenu(feedback: $feedback, onAutomatic: onAutomatic, onManual: onManual))
        } else {
            content
        }
    }
}

// MARK: - Header search menu

struct HeaderSearchMenu: View {
    let feedback: SearchFeedback
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
                if feedback == .idle {
                    Image(systemName: "magnifyingglass")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(.secondary)
                } else {
                    SearchFeedbackIcon(feedback: feedback, size: 13)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(feedback.isSending)
        .help(Text("Search", bundle: .module))
        .accessibilityLabel(feedback.isSending
                            ? Text("detail.searchingForRelease.label", bundle: .module)
                            : Text("Search", bundle: .module))
    }
}
