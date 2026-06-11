import os

/// Single source of truth for ArrBarr's unified-logging identity, so Console /
/// `log show` / `log stream` filtering is uniform across the whole app:
/// `log stream --predicate 'subsystem == "pl.incred.ArrBarr"'`.
public enum AppLog {
    public static let subsystem = "pl.incred.ArrBarr"
}

public extension Logger {
    /// An os.Logger on the shared ArrBarr subsystem. Pass a per-module
    /// `category` (e.g. "ImageCache", "Realtime"). Prefer this over spelling
    /// out the subsystem string at each call site.
    ///
    /// Level note: os `.info`/`.debug` are NOT persisted to `log show` (only
    /// streamed live). Use `.notice` for events you want to find after the
    /// fact, and reserve `.debug`/`.info` for high-volume diagnostics.
    init(category: String) {
        self.init(subsystem: AppLog.subsystem, category: category)
    }
}
