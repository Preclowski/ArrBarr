import Foundation

public enum RequestPriority: Int, Sendable, Comparable, Hashable {
    case background = 0
    case interactive = 1
    case session = 2
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

public enum RetryDisposition: Sendable, Hashable {
    case idempotent
    case never
    case handshakeOnly
}

public struct RequestPlan: Sendable, Hashable {
    public enum AuthPlacement: Sendable, Hashable {
        case header(String)
        case bearer
        case basic
        case jellyfinMediaBrowser
        case querySecret(String)
        case session
        case none
    }

    public var instance: InstanceID
    public var operation: OperationID
    public var method: String
    public var pathTemplate: String
    public var pathValues: [String: String]
    public var query: [QueryItem]
    public var headers: HTTPHeaders
    public var body: HTTPRequest.Body
    public var auth: AuthPlacement
    public var priority: RequestPriority
    public var retry: RetryDisposition
    public var timeout: Duration
    public var rpcMethod: String?

    public struct QueryItem: Sendable, Hashable {
        public let name: String, value: String
        public init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }

    public init(instance: InstanceID, operation: String, method: String = "GET", pathTemplate: String,
                pathValues: [String: String] = [:], query: [QueryItem] = [], headers: HTTPHeaders = [:],
                body: HTTPRequest.Body = .none, auth: AuthPlacement, priority: RequestPriority = .interactive,
                retry: RetryDisposition? = nil, timeout: Duration = .seconds(15), rpcMethod: String? = nil) {
        self.instance = instance
        self.operation = OperationID(instance.kind, operation)
        self.method = method; self.pathTemplate = pathTemplate; self.pathValues = pathValues
        self.query = query; self.headers = headers; self.body = body; self.auth = auth
        self.priority = priority
        self.retry = retry ?? (method == "GET" ? .idempotent : .never)
        self.timeout = timeout; self.rpcMethod = rpcMethod
    }

    /// Sorted, secret-free "k=v" pairs: the cache discriminator.
    public var discriminator: String {
        let pairs = pathValues.map { "\($0.key)=\($0.value)" } + query.map { "\($0.name)=\($0.value)" }
        return pairs.sorted().joined(separator: "&")
    }

    public static func == (l: RequestPlan, r: RequestPlan) -> Bool {
        l.instance == r.instance && l.operation == r.operation && l.method == r.method && l.pathTemplate == r.pathTemplate
            && l.discriminator == r.discriminator && l.rpcMethod == r.rpcMethod && l.bodyDigest == r.bodyDigest
    }
    public func hash(into h: inout Hasher) {
        h.combine(instance); h.combine(operation); h.combine(method); h.combine(pathTemplate); h.combine(discriminator); h.combine(rpcMethod); h.combine(bodyDigest)
    }

    private var bodyDigest: Int {
        switch body {
        case .none: 0
        case let .bytes(d, _): d.hashValue
        case let .form(f): f.hashValue
        case let .multipart(f, file): f.hashValue ^ (file?.data.hashValue ?? 0)
        }
    }
}
