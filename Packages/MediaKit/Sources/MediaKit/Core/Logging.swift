import Foundation
import os

public enum LogLevel: Sendable { case debug, notice, error, fault }

public protocol LogSink: Sendable {
    func log(_ level: LogLevel, category: String, _ message: @autoclosure () -> String, privateFields: [String: String])
}

extension LogSink {
    public func log(_ level: LogLevel, category: String, _ message: @autoclosure () -> String) {
        log(level, category: category, message(), privateFields: [:])
    }
}

public struct NoLog: LogSink {
    public init() {}
    public func log(_ level: LogLevel, category: String, _ message: @autoclosure () -> String, privateFields: [String: String]) {}
}

public struct OSLogSink: LogSink {
    private let subsystem: String
    private let loggers: OSAllocatedUnfairLock<[String: Logger]>

    public init(subsystem: String) {
        self.subsystem = subsystem
        loggers = OSAllocatedUnfairLock(initialState: [:])
    }

    public func log(_ level: LogLevel, category: String, _ message: @autoclosure () -> String, privateFields: [String: String]) {
        let logger = loggers.withLock { table -> Logger in
            if let existing = table[category] { return existing }
            let made = Logger(subsystem: subsystem, category: "MediaKit.\(category)")
            table[category] = made
            return made
        }
        let text = message()
        let fields = privateFields.keys.sorted().map { "\($0)=\(privateFields[$0]!)" }.joined(separator: " ")
        switch level {
        case .debug: logger.debug("\(text, privacy: .public) \(fields, privacy: .private)")
        case .notice: logger.notice("\(text, privacy: .public) \(fields, privacy: .private)")
        case .error: logger.error("\(text, privacy: .public) \(fields, privacy: .private)")
        case .fault: logger.fault("\(text, privacy: .public) \(fields, privacy: .private)")
        }
    }
}

public enum Signposts {
    public static func make(subsystem: String) -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: "MediaKit")
    }
}
