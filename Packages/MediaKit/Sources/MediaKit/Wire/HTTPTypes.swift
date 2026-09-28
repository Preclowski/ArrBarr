import Foundation

public struct HTTPHeaders: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    private var storage: [String: (name: String, value: String)] = [:]

    public init() {}
    public init(dictionaryLiteral elements: (String, String)...) {
        for (name, value) in elements { self[name] = value }
    }
    public init(_ dictionary: [String: String]) {
        for (name, value) in dictionary { self[name] = value }
    }

    public subscript(name: String) -> String? {
        get { storage[name.lowercased()]?.value }
        set {
            if let newValue { storage[name.lowercased()] = (name, newValue) } else { storage.removeValue(forKey: name.lowercased()) }
        }
    }

    public var names: [String] { storage.values.map(\.name).sorted() }
    public var dictionary: [String: String] { Dictionary(uniqueKeysWithValues: storage.values.map { ($0.name, $0.value) }) }

    public mutating func merge(_ other: HTTPHeaders) {
        for (_, pair) in other.storage { self[pair.name] = pair.value }
    }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool { lhs.dictionary == rhs.dictionary }
    public func hash(into hasher: inout Hasher) { hasher.combine(dictionary) }
}

public struct HTTPRequest: Sendable {
    public enum Body: Sendable {
        case none
        case bytes(Data, contentType: String)
        case form([String: String])
        case multipart(fields: [String: String], file: FilePart?)
    }

    public struct FilePart: Sendable {
        public let name: String, filename: String, data: Data, contentType: String
        public init(name: String, filename: String, data: Data, contentType: String) {
            self.name = name; self.filename = filename; self.data = data; self.contentType = contentType
        }
    }

    public var method: String
    public var url: URL
    public var headers: HTTPHeaders
    public var body: Body
    public var timeout: Duration
    /// Set by the pipeline, read by transports for fixture matching and logging. Never a URL.
    public var operation: OperationID
    public var pathTemplate: String
    public var rpcMethod: String?

    public init(method: String, url: URL, headers: HTTPHeaders = [:], body: Body = .none, timeout: Duration = .seconds(15),
                operation: OperationID, pathTemplate: String = "", rpcMethod: String? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.body = body; self.timeout = timeout
        self.operation = operation; self.pathTemplate = pathTemplate; self.rpcMethod = rpcMethod
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: HTTPHeaders
    public let body: Data

    public init(status: Int, headers: HTTPHeaders = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

public enum WireFrame: Sendable { case text(String), binary(Data), closed(code: Int?) }

public protocol WireSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> WireFrame
    func cancel()
}
