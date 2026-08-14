import SwiftUI

#if os(macOS)
import AppKit

/// Who currently opens `magnet:` links, as a read-only row.
///
/// It used to be a toggle. It could never work: `NSWorkspace`'s
/// `setDefaultApplication(at:toOpenURLsWithScheme:)` fails inside the App
/// Sandbox with `NSCocoaErrorDomain 256` wrapping `permErr` (-54), because
/// Launch Services refuses to let a sandboxed app change application
/// bindings. Apple's DTS confirms this is by design and not expected to work;
/// the same call against the same bundle succeeds from an unsandboxed process,
/// which is what pinned the cause down. ArrBarr is sandboxed in every build.
///
/// So the row states the fact instead of offering an action that returns an
/// error nobody can act on. Handling the links themselves has always worked —
/// the scheme is declared in `Info.plist`, so ArrBarr is offered as a choice
/// and `AppDelegate.application(_:open:)` takes it from there.
struct MagnetHandlerSection: View {
    @State private var handler: URL? = MagnetHandler.currentHandler

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: handlerName)
                    .foregroundStyle(.secondary)
            } label: {
                Text("Magnet links", bundle: .module)
            }
        } header: {
            Text("settings.magnetLinks.header", bundle: .module)
        }
        // The association is changed outside our process, so re-read it when
        // the app comes back to the front rather than caching an answer that
        // may have gone stale while the user was in a browser's settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            handler = MagnetHandler.currentHandler
        }
    }

    /// The handling app's name, or a plain "none" — never a raw path, which is
    /// noise in a settings row.
    private var handlerName: String {
        guard let handler else {
            return String(localized: "search.none.button", bundle: .module)
        }
        return FileManager.default.displayName(atPath: handler.path)
    }
}

/// Who holds the `magnet:` scheme. Read-only by necessity — see
/// `MagnetHandlerSection` for why claiming it is impossible from a sandboxed
/// app.
enum MagnetHandler {
    static let scheme = "magnet"

    /// A syntactically valid, harmless magnet used only to ask LaunchServices
    /// who would open one.
    private static var probe: URL { URL(string: "\(scheme):?xt=urn:btih:0")! }

    static var currentHandler: URL? {
        NSWorkspace.shared.urlForApplication(toOpen: probe)
    }
}
#endif
