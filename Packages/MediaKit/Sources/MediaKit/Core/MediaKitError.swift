import Foundation

public enum UnreachableKind: String, Sendable, Codable { case dns, refused, timeout, tls, offline, other }

public enum MediaKitError: Error, Sendable, Hashable {
    case notConfigured(InstanceID)
    case unreachable(Host, UnreachableKind)
    case breakerOpen(Host, until: Date)
    case rateLimited(Host, retryAfter: Duration?)
    case unauthorized(InstanceID, status: Int, serverMessage: String?)
    case rejected(InstanceID, status: Int, serverMessage: String?)
    case serverFault(InstanceID, status: Int, serverMessage: String?)
    case serviceError(InstanceID, code: String?, message: String?)
    case decoding(OperationID, detail: String)
    case unsupported(InstanceID, Capability)
    case persistence(detail: String)
    case notPermitted(OperationID)
    case fixtureMissing(OperationID)

    public var caseName: String {
        switch self {
        case .notConfigured: "notConfigured"
        case .unreachable: "unreachable"
        case .breakerOpen: "breakerOpen"
        case .rateLimited: "rateLimited"
        case .unauthorized: "unauthorized"
        case .rejected: "rejected"
        case .serverFault: "serverFault"
        case .serviceError: "serviceError"
        case .decoding: "decoding"
        case .unsupported: "unsupported"
        case .persistence: "persistence"
        case .notPermitted: "notPermitted"
        case .fixtureMissing: "fixtureMissing"
        }
    }

    public var serverMessage: String? {
        switch self {
        case let .unauthorized(_, _, m), let .rejected(_, _, m), let .serverFault(_, _, m): m
        case let .serviceError(_, _, m): m
        default: nil
        }
    }

    public var host: Host? {
        switch self {
        case let .unreachable(h, _), let .breakerOpen(h, _), let .rateLimited(h, _): h
        default: nil
        }
    }

    public var instance: InstanceID? {
        switch self {
        case let .notConfigured(i), let .unauthorized(i, _, _), let .rejected(i, _, _),
             let .serverFault(i, _, _), let .serviceError(i, _, _), let .unsupported(i, _): i
        default: nil
        }
    }

    /// Retryable by an idempotent read: the host may come back or the throttle may lift.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .rateLimited: true
        case let .serverFault(_, status, _): status == 502 || status == 503 || status == 504
        default: false
        }
    }
}
