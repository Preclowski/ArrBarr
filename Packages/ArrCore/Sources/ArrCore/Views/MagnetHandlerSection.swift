import SwiftUI

#if os(macOS)
import AppKit

/// Whether ArrBarr is the system handler for `magnet:` links, as a toggle.
///
/// The toggle reads the *system's* answer, not a preference of ours — that's
/// the only truthful source, since the user can reassign the scheme from
/// another app at any time. Turning it on claims the scheme; turning it off
/// hands it back to whoever held it before (see `MagnetHandler`).
struct MagnetHandlerSection: View {
    @State private var isDefault = MagnetHandler.isDefault
    @State private var failure: String?

    var body: some View {
        Section {
            Toggle(isOn: binding) {
                Text("Magnet links", bundle: .module)
            }
            // Why the switch can refuse to go back off lives here rather than
            // in a helper line under the row — it's an edge case, not
            // something worth a permanent paragraph.
            .help(Text("Opens magnet links from your browser in ArrBarr. Turning this off restores the app that handled them before.", bundle: .module))

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        // The confirmation is answered outside our process, so the truth is
        // re-read when the app comes back to the front rather than assumed
        // from the call's own result.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = MagnetHandler.isDefault
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isDefault },
            set: { wanted in
                Task { await apply(wanted) }
            }
        )
    }

    private func apply(_ wanted: Bool) async {
        failure = nil
        // Optimistic, then corrected by the real state below: without this the
        // switch sits in its old position for the whole system round-trip.
        isDefault = wanted
        do {
            if wanted {
                try await MagnetHandler.claim()
            } else {
                try await MagnetHandler.release()
            }
        } catch {
            failure = error.localizedDescription
        }
        isDefault = MagnetHandler.isDefault
    }
}

/// The `magnet:` scheme registration — kept out of the view so the check, the
/// claim and the hand-back have one testable home.
enum MagnetHandler {
    static let scheme = "magnet"
    /// Bundle URL of whoever held the scheme before we took it, so turning the
    /// toggle back off is a real hand-back rather than a no-op. macOS offers no
    /// way to *clear* a scheme's handler — only to point it somewhere — so
    /// without this there'd be nothing to turn off to.
    private static let previousHandlerKey = "ArrBarr.magnetPreviousHandler"

    /// A syntactically valid, harmless magnet used only to ask LaunchServices
    /// who would open one.
    private static var probe: URL { URL(string: "\(scheme):?xt=urn:btih:0")! }

    static var currentHandler: URL? {
        NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    /// Compares bundle URLs rather than identifiers so a debug build running
    /// beside a released one reports the truth for the copy you're actually in.
    static var isDefault: Bool {
        currentHandler?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func claim() async throws {
        if let previous = currentHandler, previous.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL {
            UserDefaults.standard.set(previous.path, forKey: previousHandlerKey)
        }
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
    }

    /// Hand the scheme back. Throws when there's nothing to hand it back to —
    /// the honest outcome, since macOS can't leave a scheme unassigned.
    static func release() async throws {
        guard let path = UserDefaults.standard.string(forKey: previousHandlerKey),
              FileManager.default.fileExists(atPath: path) else {
            throw MagnetHandlerError.noPreviousHandler
        }
        try await NSWorkspace.shared.setDefaultApplication(
            at: URL(fileURLWithPath: path),
            toOpenURLsWithScheme: scheme
        )
        UserDefaults.standard.removeObject(forKey: previousHandlerKey)
    }
}

enum MagnetHandlerError: LocalizedError {
    case noPreviousHandler
    var errorDescription: String? {
        String(
            localized: "macOS has no app to hand magnet links back to. Pick one in another app's settings.",
            bundle: .module
        )
    }
}
#endif
