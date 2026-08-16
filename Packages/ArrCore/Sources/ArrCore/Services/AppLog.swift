import Foundation
import os

/// Single source of truth for ArrBarr's unified-logging identity, so Console /
/// `log show` / `log stream` filtering is uniform across the whole app:
/// `log stream --predicate 'subsystem == "pl.incred.ArrBarr"'`.
public enum AppLog {
    public static let subsystem = "pl.incred.ArrBarr"
}

public extension Logger {
    /// An os.Logger on the shared ArrBarr subsystem. Pass a per-module
    /// `category` (e.g. "PosterStore", "Realtime"). This is the ONLY supported
    /// way to make a logger — never spell out the subsystem at a call site, and
    /// hold the result in a `static let` rather than building one per call.
    ///
    /// ## Which level
    ///
    /// os `.info`/`.debug` are NOT persisted to `log show` — they only exist in
    /// a live `log stream`. That makes the choice a question of "will I want
    /// this after the fact?", not of how interesting it feels while writing it:
    ///
    /// - `.debug` — periodic or per-item background work: a poster fetch, a
    ///   cache purge, a reconnect cycle, an index refresh. These repeat, and
    ///   promoting them evicts the entries below from the persistent store.
    /// - `.notice` — one-shot events with a user-visible consequence: a tool
    ///   the AI ran, the MCP server binding, a drop landing, a sync starting.
    ///   Rule of thumb: if a support question could be answered by seeing it
    ///   an hour later, it is `.notice`.
    /// - `.error` — something failed that the user may feel. External causes:
    ///   the arr is down, the Keychain refused, a decode broke.
    /// - `.fault` — OUR invariant broke: a state the code says cannot happen.
    ///   Never used for a server or network that merely misbehaved.
    ///
    /// ## What may be public
    ///
    /// Counts, ids, enum cases, HTTP statuses and our own literals are
    /// `.public`. The user's library content — titles, people, file names — and
    /// anything carrying their infrastructure (full URLs, hosts, query strings)
    /// is `.private`, because the unified log is collected wholesale by a
    /// sysdiagnose.
    ///
    /// `.private` redacts in Debug builds too. To read those lines while
    /// working on the app, turn private data on for this subsystem once:
    /// `sudo log config --subsystem pl.incred.ArrBarr --mode private_data:on`.
    /// That is deliberately a machine-level opt-in rather than an `#if DEBUG`
    /// dance in our own code — one mechanism, and the shipped statement is the
    /// same one that was tested.
    init(category: String) {
        self.init(subsystem: AppLog.subsystem, category: category)
    }
}

public extension URL {
    /// `scheme://host[:port]/path` — enough to tell which server was talked to,
    /// without the query string.
    ///
    /// The query is where the secrets are. Servarr accepts a legacy
    /// `?apikey=…` and some users' pasted base URLs still carry one; SABnzbd
    /// puts its key there by design; Plex's transcode endpoint folds the whole
    /// original item path into `url=`. Anything logging a URL uses this, and
    /// then still marks it `.private` — the host itself is the user's
    /// infrastructure.
    var loggableDescription: String {
        guard let c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return "?" }
        let port = c.port.map { ":\($0)" } ?? ""
        return "\(c.scheme ?? "?")://\(c.host ?? "?")\(port)\(c.path)"
    }
}

/// Signposts for Instruments' os_signpost track. Logs answer "what happened";
/// these answer "how long did it take, and did they overlap" — which the queue
/// refresh (fan-out over four arrs plus side-loads) and the poster prefetch
/// cannot be reasoned about without.
///
/// Signposts are compiled out of the measurement path when nothing is
/// recording, so these stay in shipped builds.
public enum AppSignpost {
    public static let queue = OSSignposter(subsystem: AppLog.subsystem, category: "QueueFetch")
    public static let posters = OSSignposter(subsystem: AppLog.subsystem, category: "PosterStore")
}
