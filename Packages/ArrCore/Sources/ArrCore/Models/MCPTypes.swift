import Foundation

// MARK: - JSON value (schema-less JSON)

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - JSON-RPC 2.0 envelope

public struct JSONRPCRequest: Encodable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let method: String
    public let params: JSONValue

    public init(id: Int, method: String, params: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification: Encodable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue

    public init(method: String, params: JSONValue) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

public struct JSONRPCError: Decodable, Equatable, Sendable {
    public let code: Int
    public let message: String
}

public struct JSONRPCResponse<R: Decodable & Sendable>: Decodable, Sendable {
    public let jsonrpc: String
    public let id: Int?
    public let result: R?
    public let error: JSONRPCError?
}

// MARK: - MCP method-specific result payloads

public struct MCPTool: Decodable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
}

public struct ToolsListResult: Decodable, Sendable, Equatable {
    public let tools: [MCPTool]
}

public struct InitializeResult: Decodable, Sendable, Equatable {
    public let protocolVersion: String
    public let serverInfo: ServerInfo?

    public struct ServerInfo: Decodable, Sendable, Equatable {
        public let name: String?
        public let version: String?
    }
}

public struct ToolsCallContent: Decodable, Sendable, Equatable {
    public let type: String
    public let text: String?
}

public struct ToolsCallResult: Decodable, Sendable, Equatable {
    public let content: [ToolsCallContent]
    public let isError: Bool?
}
