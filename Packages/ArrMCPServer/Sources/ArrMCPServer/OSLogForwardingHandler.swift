import ArrCore
import Logging
import os

/// Forwards swift-log into `os.Logger`. Bootstrap once at launch.
public struct OSLogForwardingHandler: LogHandler {
    private let osLogger: os.Logger
    /// swift-log filters before os.Logger sees anything, so pass everything and
    /// let unified logging filter.
    public var logLevel: Logging.Logger.Level = .trace
    public var metadata: Logging.Logger.Metadata = [:]

    public init(label: String) {
        self.osLogger = os.Logger(subsystem: AppLog.subsystem, category: label)
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// Message and metadata go out `.public`: only our literals, tool names, counts,
    /// ids and framework diagnostics may pass through this bridge.
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
        // `.default` is persisted, so lifecycle lines show in `log show`.
        case .notice: return .default
        case .warning, .error: return .error
        case .critical: return .fault
        }
    }
}
