import Foundation

public struct RTorrentService: DownloadService {
    public let instance: InstanceID
    public init(instance: InstanceID) { self.instance = instance }

    private static let fields = ["d.hash=", "d.name=", "d.completed_bytes=", "d.size_bytes=", "d.down.rate=", "d.state=", "d.is_active=", "d.custom1="]

    private func call(_ op: String, method: String, params: [XMLRPC.Value] = [], priority: RequestPriority = .interactive) -> RequestPlan {
        RequestPlan(instance: instance, operation: op, method: "POST", pathTemplate: "/RPC2", body: .bytes(XMLRPC.request(method: method, params: params), contentType: "text/xml"),
                    auth: .basic, priority: priority, retry: method.hasPrefix("system.") || method == "d.multicall2" ? .idempotent : .never, rpcMethod: method)
    }

    public func version() -> Resource<String> {
        Resource(plan: call("testConnection", method: "system.client_version"), tags: [.capabilities(instance)], freshness: .reference) { data in
            (try? XMLRPC.parse(data))?.stringValue ?? ""
        }
    }

    public func tasks(ids: Set<String>) -> RequestPlan {
        call("fetchProgress", method: "d.multicall2", params: [.string(""), .string("main")] + Self.fields.map { .string($0) }, priority: .background)
    }

    public func decodeTasks(_ response: HTTPResponse, ids: Set<String>) throws -> [DownloadTask] {
        let op = OperationID(instance.kind, "fetchProgress")
        let value: XMLRPC.Value
        do { value = try XMLRPC.parse(response.body) } catch { throw MediaKitError.decoding(op, detail: "\(error)") }
        if case let .fault(code, message) = value { throw MediaKitError.serviceError(instance, code: String(code), message: message) }
        guard case let .array(rows) = value else { throw MediaKitError.decoding(op, detail: "multicall result is not an array") }
        return rows.compactMap { row in
            // Positional alignment with `fields` is the contract; a short row is a decode error, not a guess.
            guard case let .array(cols) = row, cols.count >= Self.fields.count, let hash = cols[0].stringValue else { return nil }
            let completed = Double(cols[2].intValue ?? 0), size = Double(cols[3].intValue ?? 0)
            let active = (cols[6].intValue ?? 0) == 1, open = (cols[5].intValue ?? 0) == 1
            let state: DownloadTask.State = !open ? .paused : !active ? .paused : completed >= size && size > 0 ? .seeding : .downloading
            return DownloadTask(id: hash, name: cols[1].stringValue ?? hash, state: state, progress: size > 0 ? completed / size : 0,
                                downloadSpeed: cols[4].intValue.map(Int64.init), sizeBytes: Int64(size), category: cols[7].stringValue, instance: instance)
        }
    }

    public func defaultAddPaused() -> Resource<Bool?> {
        Resource(plan: call("defaultAddPaused", method: "system.client_version"), tags: [.capabilities(instance)], freshness: .reference) { _ in nil }
    }

    public func action(_ action: DownloadAction, ids: [String], deleteFiles: Bool) -> Command {
        guard action != .forceStart else { return Self.unsupportedForceStart(instance) }
        let method = switch action { case .pause: "d.stop"; case .resume: "d.start"; default: "d.erase" }
        let service = self
        return command(action.rawValue) { ctx in
            for id in ids { _ = try await ctx.send(service.call(action.rawValue, method: method, params: [.string(id.uppercased())])) }
            return CommandReceipt(acceptedAt: ctx.clock.now)
        }
    }

    public func add(_ payload: DownloadPayload, category: String?, paused: Bool) -> Command {
        let label = category.map { "d.custom1.set=\($0)" }
        let p = switch payload.content {
        case let .magnet(link): call("addMagnet", method: paused ? "load.normal" : "load.start", params: [.string(""), .string(link)] + (label.map { [.string($0)] } ?? []))
        case let .file(data, _): call("addFile", method: paused ? "load.raw" : "load.raw_start", params: [.string(""), .base64(data)] + (label.map { [.string($0)] } ?? []))
        }
        return command(p.operation.name) { ctx in _ = try await ctx.send(p); return CommandReceipt(acceptedAt: ctx.clock.now) }
    }
}

/// The six calls above need strings, ints, base64 and arrays; nothing else is encoded or parsed.
enum XMLRPC {
    indirect enum Value: Equatable {
        case string(String), int(Int), bool(Bool), base64(Data), array([Value]), fault(code: Int, message: String)
        var stringValue: String? { if case let .string(s) = self { s } else { nil } }
        var intValue: Int? { switch self { case let .int(i): i; case let .string(s): Int(s); case let .bool(b): b ? 1 : 0; default: nil } }
    }

    static func request(method: String, params: [Value]) -> Data {
        var xml = "<?xml version=\"1.0\"?><methodCall><methodName>\(escape(method))</methodName><params>"
        for p in params { xml += "<param>\(encode(p))</param>" }
        xml += "</params></methodCall>"
        return Data(xml.utf8)
    }

    private static func encode(_ v: Value) -> String {
        switch v {
        case let .string(s): "<value><string>\(escape(s))</string></value>"
        case let .int(i): "<value><i8>\(i)</i8></value>"
        case let .bool(b): "<value><boolean>\(b ? 1 : 0)</boolean></value>"
        case let .base64(d): "<value><base64>\(d.base64EncodedString())</base64></value>"
        case let .array(a): "<value><array><data>\(a.map(encode).joined())</data></array></value>"
        case .fault: ""
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func parse(_ data: Data) throws -> Value {
        let parser = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw parser.error ?? xml.parserError ?? URLError(.cannotParseResponse) }
        if let fault = parser.fault { return fault }
        guard let root = parser.root else { throw URLError(.cannotParseResponse) }
        return root
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var root: Value?
        var fault: Value?
        var error: (any Error)?
        private var stack: [[Value]] = []
        private var text = ""
        private var inFault = false
        private var faultMembers: [String: Value] = [:]
        private var memberName = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            switch name {
            case "array": stack.append([])
            case "fault": inFault = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            var value: Value?
            switch name {
            case "string": value = .string(text)
            case "int", "i4", "i8": value = .int(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            case "boolean": value = .bool(text.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
            case "base64": value = .base64(Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Data())
            case "array": value = .array(stack.popLast() ?? [])
            case "name": memberName = text
            case "member": if inFault, let last = stack.last?.last { faultMembers[memberName] = last; _ = stack[stack.count - 1].popLast() }
            case "fault":
                inFault = false
                fault = .fault(code: faultMembers["faultCode"]?.intValue ?? 0, message: faultMembers["faultString"]?.stringValue ?? "")
            case "struct" where inFault: break
            default: break
            }
            guard let value else { return }
            if stack.isEmpty { root = value } else { stack[stack.count - 1].append(value) }
        }

        func parser(_ parser: XMLParser, didStartElement: String) {}
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) { error = parseError }
    }
}
