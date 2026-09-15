import Foundation
import os

public enum HostHealth: Sendable, Equatable {
    case unknown
    case healthy
    case degraded(consecutiveFailures: Int)
    case down(since: Date, retryAt: Date)
    case throttled(until: Date)
}

/// One actor for every host: limiter, rate gate and breaker are one mutable cell per host.
public actor HostGovernor {
    public struct Limits: Sendable, Equatable {
        public var maxConcurrent = 4
        public var backgroundShare = 2
        public var reservedSessionSlots = 1
        public var minimumInterval: Duration? = nil
        public var failureThreshold = 3
        public var openFor: Duration = .seconds(30)
        public init() {}
    }

    public struct Slot: Sendable {
        let host: Host
        let id: UInt64
        let priority: RequestPriority
    }

    public enum Outcome: Sendable { case success, transportFailure(MediaKitError), retryAfter(Duration), cancelled }

    private struct Waiter {
        let id: UInt64
        let priority: RequestPriority
        let continuation: CheckedContinuation<Slot, any Error>
    }

    private struct Cell {
        var limits: Limits
        var active: [UInt64: RequestPriority] = [:]
        var waiters: [Waiter] = []
        var lastSend: Date?
        var consecutiveFailures = 0
        var health: HostHealth = .unknown
        var openCount = 0
        var halfOpenProbeGranted = false
    }

    private var cells: [Host: Cell] = [:]
    private var nextID: UInt64 = 0
    private let defaults: Limits
    private let overrides: [InstanceKind: Limits]
    private let clock: any MediaClock
    private let telemetry: any TelemetrySink
    private let log: any LogSink
    private let snapshot = OSAllocatedUnfairLock<[Host: HostHealth]>(initialState: [:])
    private var healthContinuations: [UUID: AsyncStream<(Host, HostHealth)>.Continuation] = [:]

    public init(defaults: Limits = Limits(), overrides: [InstanceKind: Limits] = [:], clock: any MediaClock,
                telemetry: any TelemetrySink, log: any LogSink) {
        self.defaults = defaults; self.overrides = overrides; self.clock = clock; self.telemetry = telemetry; self.log = log
    }

    /// Throws `.breakerOpen` / `.rateLimited` before queueing when the host is shut; `CancellationError` if the task dies queued.
    public func enter(_ host: Host, kind: InstanceKind, priority: RequestPriority) async throws -> Slot {
        var cell = cells[host] ?? Cell(limits: overrides[kind] ?? defaults)
        let now = clock.now
        switch cell.health {
        case let .down(_, retryAt):
            if now < retryAt || cell.halfOpenProbeGranted {
                telemetry.record(.skipped(OperationID(kind, "enter"), host, .breakerOpen))
                throw MediaKitError.breakerOpen(host, until: retryAt)
            }
            cell.halfOpenProbeGranted = true
        case let .throttled(until):
            if now < until {
                telemetry.record(.skipped(OperationID(kind, "enter"), host, .rateLimited))
                throw MediaKitError.rateLimited(host, retryAfter: .seconds(until.timeIntervalSince(now)))
            }
            cell.health = cell.consecutiveFailures > 0 ? .degraded(consecutiveFailures: cell.consecutiveFailures) : .healthy
        default: break
        }
        cells[host] = cell
        let id = nextID
        nextID += 1
        if canStart(priority, in: cell) {
            return try await start(Slot(host: host, id: id, priority: priority))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Slot, any Error>) in
                cells[host]!.waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.removeWaiter(host: host, id: id) }
        }
    }

    public func leave(_ slot: Slot, outcome: Outcome) {
        guard var cell = cells[slot.host] else { return }
        cell.active.removeValue(forKey: slot.id)
        let now = clock.now
        switch outcome {
        case .success:
            if case .down = cell.health { telemetry.record(.breakerClosed(slot.host)); log.log(.notice, category: "Governor", "breaker closed \(slot.host)") }
            cell.consecutiveFailures = 0
            cell.openCount = 0
            cell.halfOpenProbeGranted = false
            if case .throttled = cell.health {} else { cell.health = .healthy }
        case .transportFailure:
            cell.consecutiveFailures += 1
            let wasDown: Bool = { if case .down = cell.health { true } else { false } }()
            if wasDown || cell.consecutiveFailures >= cell.limits.failureThreshold {
                cell.openCount += 1
                let factor = min(pow(2.0, Double(cell.openCount - 1)), 10)
                let openFor = min(cell.limits.openFor.seconds * factor, 300)
                let retryAt = now.addingTimeInterval(openFor)
                cell.health = .down(since: wasDown ? sinceOf(cell.health, now) : now, retryAt: retryAt)
                cell.halfOpenProbeGranted = false
                telemetry.record(.breakerOpened(slot.host, until: retryAt))
                log.log(.notice, category: "Governor", "breaker open \(slot.host) for \(Int(openFor)) s")
                let dropped = cell.waiters
                cell.waiters = []
                for w in dropped { w.continuation.resume(throwing: MediaKitError.breakerOpen(slot.host, until: retryAt)) }
            } else {
                cell.health = .degraded(consecutiveFailures: cell.consecutiveFailures)
            }
        case let .retryAfter(delay):
            let until = now.addingTimeInterval(delay.seconds)
            cell.health = .throttled(until: until)
            telemetry.record(.rateLimited(slot.host, retryAfter: delay))
        case .cancelled:
            cell.halfOpenProbeGranted = false
        }
        cells[slot.host] = cell
        publish(slot.host, cell.health)
        drain(slot.host)
    }

    public nonisolated func health(of host: Host) -> HostHealth { snapshot.withLock { $0[host] ?? .unknown } }

    public func healthUpdates() -> AsyncStream<(Host, HostHealth)> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<(Host, HostHealth)>.makeStream()
        healthContinuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.dropHealthStream(id) } }
        return stream
    }

    /// Half-opens every down host so the first post-wake request probes immediately.
    public func noteWake(at date: Date) {
        for (host, var cell) in cells {
            if case let .down(since, _) = cell.health {
                cell.health = .down(since: since, retryAt: date)
                cell.halfOpenProbeGranted = false
                cells[host] = cell
                publish(host, cell.health)
            }
        }
    }

    // MARK: - Internals

    private func sinceOf(_ health: HostHealth, _ fallback: Date) -> Date {
        if case let .down(since, _) = health { return since }
        return fallback
    }

    private func canStart(_ priority: RequestPriority, in cell: Cell) -> Bool {
        let limits = cell.limits
        let sessionActive = cell.active.values.filter { $0 == .session }.count
        let regularActive = cell.active.count - sessionActive
        let regularCapacity = max(limits.maxConcurrent - limits.reservedSessionSlots, 1)
        switch priority {
        case .session: return sessionActive < limits.reservedSessionSlots || regularActive < regularCapacity
        case .interactive: return regularActive < regularCapacity
        case .background:
            let backgroundActive = cell.active.values.filter { $0 == .background }.count
            return regularActive < regularCapacity && backgroundActive < limits.backgroundShare
        }
    }

    private func start(_ slot: Slot) async throws -> Slot {
        guard var cell = cells[slot.host] else { throw CancellationError() }
        cell.active[slot.id] = slot.priority
        if let interval = cell.limits.minimumInterval, let last = cell.lastSend {
            let wait = interval.seconds - clock.now.timeIntervalSince(last)
            if wait > 0 {
                cell.lastSend = last.addingTimeInterval(interval.seconds)
                cells[slot.host] = cell
                do { try await clock.sleep(for: .seconds(wait)) } catch {
                    cells[slot.host]?.active.removeValue(forKey: slot.id)
                    drain(slot.host)
                    throw error
                }
                return slot
            }
        }
        cell.lastSend = clock.now
        cells[slot.host] = cell
        return slot
    }

    private func drain(_ host: Host) {
        guard var cell = cells[host] else { return }
        var index = 0
        while index < cell.waiters.count {
            let bandOrder: [RequestPriority] = [.session, .interactive, .background]
            guard let pick = bandOrder.lazy.compactMap({ band in cell.waiters.firstIndex { $0.priority == band } }).first(where: { canStart(cell.waiters[$0].priority, in: cell) }) else { break }
            let waiter = cell.waiters.remove(at: pick)
            cell.active[waiter.id] = waiter.priority
            cell.lastSend = clock.now
            cells[host] = cell
            waiter.continuation.resume(returning: Slot(host: host, id: waiter.id, priority: waiter.priority))
            index = 0
        }
        cells[host] = cell
    }

    private func removeWaiter(host: Host, id: UInt64) {
        guard var cell = cells[host], let index = cell.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = cell.waiters.remove(at: index)
        cells[host] = cell
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func publish(_ host: Host, _ health: HostHealth) {
        snapshot.withLock { $0[host] = health }
        for c in healthContinuations.values { c.yield((host, health)) }
    }

    private func dropHealthStream(_ id: UUID) { healthContinuations.removeValue(forKey: id) }
}
