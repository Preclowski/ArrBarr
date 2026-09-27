import Foundation
import os

/// `log stream --predicate 'subsystem == "pl.incred.ArrBarr"'`.
nonisolated public enum AppLog {
    public static let subsystem = "pl.incred.ArrBarr"
}

nonisolated public extension Logger {
    /// The only supported way to make a logger; hold it in a `static let`. Levels and privacy follow CLAUDE.md —
    /// `.info`/`.debug` are not persisted, and the unified log is collected wholesale by a sysdiagnose.
    nonisolated init(category: String) {
        self.init(subsystem: AppLog.subsystem, category: category)
    }
}

nonisolated public extension URL {
    /// The query is where secrets live (legacy `?apikey=`, SABnzbd's key, Plex's `url=`). Still mark the result `.private`.
    var loggableDescription: String {
        guard let c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return "?" }
        let port = c.port.map { ":\($0)" } ?? ""
        return "\(c.scheme ?? "?")://\(c.host ?? "?")\(port)\(c.path)"
    }
}

nonisolated extension Logger {
    /// `try?` that leaves a trace: the value, or nil with the reason logged. `what` is a fixed label, never user data.
    func attempt<T>(_ what: StaticString, level: OSLogType = .debug, _ body: () async throws -> T) async -> T? {
        do { return try await body() } catch is CancellationError { return nil } catch {
            log(level: level, "\(String(describing: what), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Timings go here, not into log lines. Compiled out of the measurement path when nothing records.
nonisolated enum AppSignpost {
    static let queue = OSSignposter(subsystem: AppLog.subsystem, category: "QueueFetch")
    static let posters = OSSignposter(subsystem: AppLog.subsystem, category: "PosterStore")
    static let chat = OSSignposter(subsystem: AppLog.subsystem, category: "Chat")
    static let quiz = OSSignposter(subsystem: AppLog.subsystem, category: "Quiz")
}
