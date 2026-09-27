import Foundation
import os

public enum SkipReason: String, Sendable { case breakerOpen, rateLimited, notConfigured }
public enum InvalidationReason: String, Sendable { case command, event, configuration, manual, sweep }

public enum TelemetryEvent: Sendable {
    case request(OperationID, Host, RequestPriority)
    case response(OperationID, Host, status: Int, bytes: Int, duration: Duration)
    case cacheHit(ResourceKey, CacheOrigin)
    case cacheMiss(ResourceKey)
    case staleServed(ResourceKey, MediaKitError)
    case coalesced(ResourceKey, waiters: Int)
    case skipped(OperationID, Host, SkipReason)
    case failure(OperationID, Host, MediaKitError)
    case invalidated(Set<InvalidationTag>, InvalidationReason)
    case breakerOpened(Host, until: Date)
    case breakerClosed(Host)
    case rateLimited(Host, retryAfter: Duration?)
    case sessionEstablished(InstanceID, generation: Int)
}

public protocol TelemetrySink: Sendable { func record(_ event: TelemetryEvent) }

public struct NoTelemetry: TelemetrySink {
    public init() {}
    public func record(_ event: TelemetryEvent) {}
}

/// Lock-guarded, not an actor: `record` runs on the governor's critical path.
public final class TelemetryRecorder: TelemetrySink, Sendable {
    public struct HostCounters: Sendable, Equatable {
        public var requests = 0, skipped = 0, failures = 0, breakerOpens = 0, rateLimits = 0, bytes = 0
        public init() {}
    }

    public struct CacheCounters: Sendable, Equatable {
        public var hits = 0, misses = 0, staleServed = 0, coalesced = 0
        public init() {}
    }

    private struct State {
        var hosts: [Host: HostCounters] = [:]
        var caches: [InstanceID: CacheCounters] = [:]
        var operations: [OperationID: Int] = [:]
        var invalidations = 0
        var since: Date
    }

    private let state: OSAllocatedUnfairLock<State>
    private let clock: any MediaClock

    public init(clock: any MediaClock = SystemClock()) {
        self.clock = clock
        state = OSAllocatedUnfairLock(initialState: State(since: clock.now))
    }

    public func record(_ event: TelemetryEvent) {
        state.withLock { s in
            func host(_ h: Host, _ edit: (inout HostCounters) -> Void) { edit(&s.hosts[h, default: HostCounters()]) }
            func cache(_ k: ResourceKey, _ edit: (inout CacheCounters) -> Void) { edit(&s.caches[k.instance, default: CacheCounters()]) }
            switch event {
            case let .request(op, h, _):
                host(h) { $0.requests += 1 }
                s.operations[op, default: 0] += 1
            case let .response(_, h, _, bytes, _): host(h) { $0.bytes += bytes }
            case let .cacheHit(key, _): cache(key) { $0.hits += 1 }
            case let .cacheMiss(key): cache(key) { $0.misses += 1 }
            case let .staleServed(key, _): cache(key) { $0.staleServed += 1 }
            case let .coalesced(key, _): cache(key) { $0.coalesced += 1 }
            case let .skipped(_, h, _): host(h) { $0.skipped += 1 }
            case let .failure(_, h, _): host(h) { $0.failures += 1 }
            case .invalidated: s.invalidations += 1
            case let .breakerOpened(h, _): host(h) { $0.breakerOpens += 1 }
            case .breakerClosed: break
            case let .rateLimited(h, _): host(h) { $0.rateLimits += 1 }
            case .sessionEstablished: break
            }
        }
    }

    public func counters(for host: Host) -> HostCounters { state.withLock { $0.hosts[host] ?? HostCounters() } }
    public func cacheCounters(for instance: InstanceID) -> CacheCounters { state.withLock { $0.caches[instance] ?? CacheCounters() } }
    public func counters(for operation: OperationID) -> Int { state.withLock { $0.operations[operation] ?? 0 } }
    public var totalRequests: Int { state.withLock { $0.operations.values.reduce(0, +) } }

    /// Counters summed over every host and instance: numbers without names, safe for a public log line.
    public func totals() -> (hosts: HostCounters, caches: CacheCounters, operations: [OperationID: Int]) {
        state.withLock { s in
            let hosts = s.hosts.values.reduce(into: HostCounters()) { t, c in
                t.requests += c.requests; t.skipped += c.skipped; t.failures += c.failures
                t.breakerOpens += c.breakerOpens; t.rateLimits += c.rateLimits; t.bytes += c.bytes
            }
            let caches = s.caches.values.reduce(into: CacheCounters()) { t, c in
                t.hits += c.hits; t.misses += c.misses; t.staleServed += c.staleServed; t.coalesced += c.coalesced
            }
            return (hosts, caches, s.operations)
        }
    }

    public func report() -> String {
        let (hosts, caches, operations, since) = state.withLock { ($0.hosts, $0.caches, $0.operations, $0.since) }
        var lines = ["MediaKit telemetry since \(since) (\(clock.now.timeIntervalSince(since).rounded()) s)"]
        for host in hosts.keys.sorted(by: { $0.description < $1.description }) {
            let c = hosts[host]!
            lines.append("\(host): requests \(c.requests) skipped \(c.skipped) failures \(c.failures) breaker \(c.breakerOpens) 429 \(c.rateLimits) bytes \(c.bytes)")
        }
        for instance in caches.keys.sorted(by: { $0.description < $1.description }) {
            let c = caches[instance]!
            lines.append("\(instance): hits \(c.hits) misses \(c.misses) stale \(c.staleServed) coalesced \(c.coalesced)")
        }
        for (op, count) in operations.sorted(by: { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }).prefix(10) {
            lines.append("  \(op.rawValue): \(count)")
        }
        return lines.joined(separator: "\n")
    }

    public func reset() { state.withLock { $0 = State(since: clock.now) } }
}
