import Foundation

/// One thing that happened in the data layer.
///
/// The debug mode exists because the interesting bugs in a layer like this are
/// invisible from the UI: the screen looks right while the same title is
/// fetched eleven times, the cache never hits because a key carries a
/// timestamp, or every card quietly asks a metered API for a field the LAN
/// could have answered. Counting is the only way to see any of it.
public struct MediaTelemetryEvent: Sendable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// The planner asked a provider for fields.
        case request
        /// The provider answered over the wire (`bytes`, `duration`). The gap
        /// between `request` and `response` counts is what the cache saved.
        case response
        /// This provider's answer WON these fields in the merge. Separate from
        /// `response` because the interesting question is not who replied but
        /// whose reply ended up on screen.
        case served
        case cacheHit
        case cacheMiss
        /// A second caller joined an in-flight request instead of starting one.
        case coalesced
        /// Provider skipped: not configured, can't supply the field, unhealthy.
        case skipped
        case failure
    }

    public let id: UUID
    public let at: Date
    public let kind: Kind
    public let provider: ProviderID
    public let identity: String
    public let fields: MediaFieldSet
    /// Wall-clock cost of a `response` / `failure`.
    public let duration: TimeInterval?
    /// Wire bytes, when the transport can report them.
    public let bytes: Int?
    public let note: String?

    public init(kind: Kind, provider: ProviderID, identity: String,
                fields: MediaFieldSet, duration: TimeInterval? = nil,
                bytes: Int? = nil, note: String? = nil, at: Date = Date()) {
        self.id = UUID()
        self.at = at
        self.kind = kind
        self.provider = provider
        self.identity = identity
        self.fields = fields
        self.duration = duration
        self.bytes = bytes
        self.note = note
    }
}

/// Per-provider running totals — the part you read when asking "who is
/// costing me what".
public struct ProviderUsage: Sendable, Hashable {
    /// Wire volume, written the way a human reads it — a 900-byte answer
    /// rounded to "0 KB" is how you miss that a call happened at all.
    public var bytesDescription: String {
        bytes < 10_240
            ? "\(bytes) B"
            : "\(bytes / 1024) KB"
    }

    public var provider: ProviderID
    public var requests = 0
    public var responses = 0
    public var failures = 0
    public var cacheHits = 0
    public var cacheMisses = 0
    public var coalesced = 0
    public var skipped = 0
    public var bytes = 0
    public var totalDuration: TimeInterval = 0

    public init(provider: ProviderID) { self.provider = provider }

    public var averageDuration: TimeInterval {
        responses > 0 ? totalDuration / Double(responses) : 0
    }

    /// The number that matters for a cache: of the lookups that could have
    /// been served from cache, how many were.
    public var cacheHitRate: Double {
        let total = cacheHits + cacheMisses
        return total > 0 ? Double(cacheHits) / Double(total) : 0
    }
}

public struct MediaUsageReport: Sendable {
    public let since: Date
    public let providers: [ProviderUsage]
    /// How often each field was asked for, and who ended up answering it.
    public let fieldRequests: [MediaField: Int]
    public let fieldAnswers: [MediaField: [ProviderID: Int]]
    public let recent: [MediaTelemetryEvent]

    /// Same title fetched from the same provider more than once in the
    /// window — nearly always a missing cache key or a view that rebuilds.
    public let repeatedFetches: [String: Int]

    /// Plain-text dump for a debug panel, a log line, or a paste into an
    /// issue. Deliberately free of secrets: identities and provider names
    /// only, never URLs or keys.
    public func formatted() -> String {
        var lines: [String] = []
        lines.append("MediaKit usage since \(since.formatted(date: .omitted, time: .standard))")
        for usage in providers.sorted(by: { $0.requests > $1.requests }) {
            let hitRate = Int(usage.cacheHitRate * 100)
            let ms = Int(usage.averageDuration * 1000)
            lines.append("""
                \(usage.provider.rawValue): \(usage.responses)/\(usage.requests) ok, \
                \(usage.failures) failed, \(usage.skipped) skipped, \
                cache \(usage.cacheHits)/\(usage.cacheHits + usage.cacheMisses) (\(hitRate)%), \
                coalesced \(usage.coalesced), \(usage.bytesDescription), avg \(ms) ms
                """)
        }
        for field in MediaField.allCases {
            guard let asked = fieldRequests[field], asked > 0 else { continue }
            let answers = (fieldAnswers[field] ?? [:])
                .sorted { $0.value > $1.value }
                .map { "\($0.key.rawValue) \($0.value)" }
                .joined(separator: ", ")
            lines.append("  \(field.rawValue): asked \(asked) → \(answers.isEmpty ? "unanswered" : answers)")
        }
        if !repeatedFetches.isEmpty {
            lines.append("repeated fetches (suspect cache keys):")
            for (key, count) in repeatedFetches.sorted(by: { $0.value > $1.value }).prefix(10) {
                lines.append("  \(key) ×\(count)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// The debug recorder. Off by default and cheap when off: every call site
/// checks `isEnabled` first, so a disabled recorder costs one actor hop and
/// no allocation.
///
/// Enabled by `MEDIAKIT_DEBUG=1` in the environment, or programmatically from
/// a debug menu.
public actor MediaTelemetry {
    public static let shared = MediaTelemetry(
        enabled: ProcessInfo.processInfo.environment["MEDIAKIT_DEBUG"] == "1")

    public private(set) var isEnabled: Bool
    private var since = Date()
    private var usage: [ProviderID: ProviderUsage] = [:]
    private var fieldRequests: [MediaField: Int] = [:]
    private var fieldAnswers: [MediaField: [ProviderID: Int]] = [:]
    private var fetchCounts: [String: Int] = [:]
    /// Ring buffer — a debug session must not grow without bound.
    private var recent: [MediaTelemetryEvent] = []
    private let recentCapacity = 500

    public init(enabled: Bool = false) { self.isEnabled = enabled }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled { reset() }
    }

    public func record(_ event: MediaTelemetryEvent) {
        guard isEnabled else { return }
        var entry = usage[event.provider] ?? ProviderUsage(provider: event.provider)
        switch event.kind {
        case .request:
            entry.requests += 1
            for field in event.fields.fields { fieldRequests[field, default: 0] += 1 }
            let key = "\(event.provider.rawValue) \(event.identity)"
            fetchCounts[key, default: 0] += 1
        case .response:
            entry.responses += 1
            entry.bytes += event.bytes ?? 0
            entry.totalDuration += event.duration ?? 0
        case .served:
            for field in event.fields.fields {
                fieldAnswers[field, default: [:]][event.provider, default: 0] += 1
            }
        case .cacheHit: entry.cacheHits += 1
        case .cacheMiss: entry.cacheMisses += 1
        case .coalesced: entry.coalesced += 1
        case .skipped: entry.skipped += 1
        case .failure:
            entry.failures += 1
            entry.totalDuration += event.duration ?? 0
        }
        usage[event.provider] = entry

        recent.append(event)
        if recent.count > recentCapacity { recent.removeFirst(recent.count - recentCapacity) }
    }

    public func report() -> MediaUsageReport {
        MediaUsageReport(
            since: since,
            providers: Array(usage.values),
            fieldRequests: fieldRequests,
            fieldAnswers: fieldAnswers,
            recent: recent,
            repeatedFetches: fetchCounts.filter { $0.value > 1 })
    }

    public func reset() {
        since = Date()
        usage.removeAll()
        fieldRequests.removeAll()
        fieldAnswers.removeAll()
        fetchCounts.removeAll()
        recent.removeAll()
    }
}

/// Timing helper so providers don't each reinvent the stopwatch. Records a
/// `request` up front and a `response`/`failure` when the work returns, so a
/// crash mid-flight still leaves the request visible in the trace.
public func withTelemetry<T: Sendable>(
    _ telemetry: MediaTelemetry,
    provider: ProviderID,
    identity: MediaIdentity,
    fields: MediaFieldSet,
    work: () async throws -> T
) async rethrows -> T {
    let key = identity.cacheKey
    await telemetry.record(.init(kind: .request, provider: provider,
                                 identity: key, fields: fields))
    let started = Date()
    do {
        let value = try await work()
        let populated = (value as? MediaFragment)?.populated ?? fields
        await telemetry.record(.init(kind: .response, provider: provider,
                                     identity: key, fields: populated,
                                     duration: Date().timeIntervalSince(started)))
        return value
    } catch {
        await telemetry.record(.init(kind: .failure, provider: provider,
                                     identity: key, fields: fields,
                                     duration: Date().timeIntervalSince(started),
                                     note: "\(error)"))
        throw error
    }
}
