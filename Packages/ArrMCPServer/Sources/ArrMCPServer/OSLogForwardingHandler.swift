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
    public var logLevel: Logging.Logger.Level = .info
    public var metadata: Logging.Logger.Metadata = [:]

    public init(label: String) {
        self.osLogger = os.Logger(subsystem: AppLog.subsystem, category: label)
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(level: Logging.Logger.Level,
                    message: Logging.Logger.Message,
                    metadata explicit: Logging.Logger.Metadata?,
                    source: String, file: String, function: String, line: UInt) {
        let merged = self.metadata.merging(explicit ?? [:]) { _, new in new }
        let suffix = merged.isEmpty ? ""
            : " " + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        osLogger.log(level: level.osLogType, "\(message, privacy: .public)\(suffix, privacy: .public)")
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
