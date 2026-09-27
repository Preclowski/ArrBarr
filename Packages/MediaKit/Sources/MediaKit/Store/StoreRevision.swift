import Foundation
import Observation
import os

/// The one `@Observable` type in MediaKit: lock-guarded counters with hand-written access tracking.
@Observable
public final class StoreRevision: @unchecked Sendable {
    /// `wipes` counts purges: a purge drops rows under every tag, so every tag's tick moves with it.
    private let lock = OSAllocatedUnfairLock<(all: UInt64, wipes: UInt64, tags: [InvalidationTag: UInt64])>(initialState: (0, 0, [:]))

    public init() {}

    @ObservationIgnored private var _all: UInt64 { lock.withLock { $0.all } }

    public var all: UInt64 {
        access(keyPath: \.all)
        return _all
    }

    public func tick(for tag: InvalidationTag) -> UInt64 {
        access(keyPath: \.all)
        return lock.withLock { ($0.tags[tag] ?? 0) &+ $0.wipes }
    }

    /// Every bump means "re-read now", never a delta.
    func bump(_ tags: Set<InvalidationTag>) {
        withMutation(keyPath: \.all) {
            lock.withLock { state in
                state.all += 1
                for tag in tags { state.tags[tag, default: 0] += 1 }
            }
        }
    }

    func bumpEverything() {
        withMutation(keyPath: \.all) {
            lock.withLock { state in
                state.all += 1
                state.wipes += 1
            }
        }
    }
}

/// One per MediaKit; the subject of every typed message so two kits never cross-talk.
public final class MessageSubject: Sendable { public init() {} }

public struct ConfigurationChanged: NotificationCenter.AsyncMessage {
    public typealias Subject = MessageSubject
    public let instances: Set<InstanceID>
    public init(instances: Set<InstanceID>) { self.instances = instances }
}

public struct Invalidated: NotificationCenter.AsyncMessage {
    public typealias Subject = MessageSubject
    public let tags: Set<InvalidationTag>
    public let reason: InvalidationReason
    public init(tags: Set<InvalidationTag>, reason: InvalidationReason) { self.tags = tags; self.reason = reason }
}

public struct ConnectivityChanged: NotificationCenter.AsyncMessage {
    public typealias Subject = MessageSubject
    public let host: Host
    public let instances: Set<InstanceID>
    public let health: HostHealth
    public init(host: Host, instances: Set<InstanceID>, health: HostHealth) { self.host = host; self.instances = instances; self.health = health }
}
