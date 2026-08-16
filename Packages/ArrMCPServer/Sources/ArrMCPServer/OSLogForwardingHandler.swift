import ArrCore
import Logging
import os

/// A swift-log `LogHandler` that forwards into Apple's unified logging (`os.Logger`),
/// so the MCP server's structured logs surface in Console / `log stream` /
/// `log show` alongside the rest of ArrBarr. Bootstrap it once at app launch:
///
/// ```swift
/// LoggingSystem.bootstrap { OSLogForwardingHandler(label: $0) }
/// ```
public struct OSLogForwardingHandler: LogHandler {
    private let osLogger: os.Logger
    /// Pass everything through and let unified logging do the filtering.
    ///
    /// swift-log's own level check runs FIRST, so the default `.info` silently
    /// dropped every `.debug`/`.trace` line before os.Logger ever saw it — which
    /// meant `log stream --level debug` showed nothing from the server or NIO
    /// and looked like the bridge was broken. os.Logger discards unwanted levels
    /// far more cheaply than swift-log formats them, so this is the right layer
    /// to decide.
    public var logLevel: Logging.Logger.Level = .trace
    public var metadata: Logging.Logger.Metadata = [:]

    public init(label: String) {
        self.osLogger = os.Logger(subsystem: AppLog.subsystem, category: label)
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// swift-log 1.13 made `log(event:)` the protocol requirement and demoted
    /// the flat-parameter `log(level:message:metadata:source:…)` to a
    /// deprecated shim, so implement this one directly — satisfying the
    /// protocol through the shim is what the deprecation warns about.
    ///
    /// `LogEvent` also carries an `error`, which the flat API had nowhere to
    /// put. NIO and the MCP SDK attach one to their failure lines, and it is
    /// usually the only part that says what actually went wrong.
    ///
    /// Message and metadata are interpolated `.public`, which is only safe
    /// because of what goes through this bridge: our own literals, tool names,
    /// counts, session ids, bind addresses and framework diagnostics. Nothing
    /// on this path may carry the user's library content or credentials — the
    /// per-site `privacy:` control that would normally guard that is not
    /// reachable from a swift-log call site.
    public func log(event: LogEvent) {
        let merged = self.metadata.merging(event.metadata ?? [:]) { _, new in new }
        var suffix = merged.isEmpty ? ""
            : " " + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        if let error = event.error { suffix += " error=\(error)" }
        osLogger.log(level: event.level.osLogType, "\(event.message, privacy: .public)\(suffix, privacy: .public)")
    }
}

private extension Logging.Logger.Level {
    var osLogType: OSLogType {
        switch self {
        case .trace, .debug: return .debug
        case .info: return .info
        // `.notice` -> os `.default`: unlike `.info`/`.debug`, default-level
        // entries are persisted, so the server's lifecycle logs (host bound,
        // server started, tool count) show up in `log show`, not just `log stream`.
        case .notice: return .default
        case .warning, .error: return .error
        case .critical: return .fault
        }
    }
}
