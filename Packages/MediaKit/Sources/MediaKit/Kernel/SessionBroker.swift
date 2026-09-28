import Foundation

public struct SessionToken: Sendable {
    public var headers: HTTPHeaders
    public var query: [RequestPlan.QueryItem]
    public init(headers: HTTPHeaders = [:], query: [RequestPlan.QueryItem] = []) {
        self.headers = headers; self.query = query
    }
}

public enum SessionRejection: Sendable, Equatable {
    case unauthenticated
    case handshake(header: String, value: String)
}

public typealias SessionSend = @Sendable (HTTPRequest) async throws -> HTTPResponse

public protocol SessionStrategy: Sendable {
    func authorize(_ request: HTTPRequest, plan: RequestPlan, credentials: Credentials, session: SessionToken?) throws -> HTTPRequest
    func rejection(for response: HTTPResponse) -> SessionRejection?
    /// Runs at `.session` priority through the pipeline. `nil` = this service has no session.
    func establish(after rejection: SessionRejection?, credentials: Credentials, send: SessionSend) async throws -> SessionToken?
}

/// One `establish` per generation: a burst of 403s awaits the same login.
public actor SessionBroker {
    private struct Cell {
        var token: SessionToken?
        var generation = 0
        var establishing: Task<SessionToken?, any Error>?
        var credentialGeneration: String?
    }

    private let strategies: [InstanceKind: any SessionStrategy]
    private var cells: [InstanceID: Cell] = [:]
    private let telemetry: any TelemetrySink
    private let log: any LogSink

    public init(strategies: [InstanceKind: any SessionStrategy], telemetry: any TelemetrySink, log: any LogSink) {
        self.strategies = strategies; self.telemetry = telemetry; self.log = log
    }

    public func authorize(_ plan: RequestPlan, credentials: Credentials) throws -> HTTPRequest {
        var cell = cells[plan.instance] ?? Cell()
        if cell.credentialGeneration != credentials.generation {
            cell = Cell(credentialGeneration: credentials.generation)
            cells[plan.instance] = cell
        }
        var request = HTTPRequest(
            method: plan.method,
            url: RequestBuilder.url(base: credentials.baseURL, pathTemplate: plan.pathTemplate, values: plan.pathValues,
                                    query: (plan.query + (cell.token?.query ?? [])).map { ($0.name, $0.value) }),
            headers: plan.headers, body: plan.body, timeout: plan.timeout,
            operation: plan.operation, pathTemplate: plan.pathTemplate, rpcMethod: plan.rpcMethod
        )
        if let token = cell.token { request.headers.merge(token.headers) }
        guard let strategy = strategies[plan.instance.kind] else { return request }
        return try strategy.authorize(request, plan: plan, credentials: credentials, session: cell.token)
    }

    public func rejection(for response: HTTPResponse, kind: InstanceKind) -> SessionRejection? {
        strategies[kind]?.rejection(for: response)
    }

    /// Returns false when the strategy has no session to refresh (the rejection is final).
    @discardableResult
    public func refresh(_ instance: InstanceID, after rejection: SessionRejection?, credentials: Credentials,
                        observedGeneration: Int, send: @escaping SessionSend) async throws -> Bool {
        guard let strategy = strategies[instance.kind] else { return false }
        var cell = cells[instance] ?? Cell()
        if cell.generation > observedGeneration { return true }   // someone already refreshed
        if let task = cell.establishing {
            _ = try await task.value
            return cells[instance]?.token != nil
        }
        let task = Task { try await strategy.establish(after: rejection, credentials: credentials, send: send) }
        cell.establishing = task
        cells[instance] = cell
        defer { cells[instance]?.establishing = nil }
        let token = try await task.value
        guard var updated = cells[instance] else { return false }
        updated.generation += 1
        updated.token = token
        cells[instance] = updated
        if token != nil {
            telemetry.record(.sessionEstablished(instance, generation: updated.generation))
            log.log(.notice, category: "Session", "session established \(instance) generation \(updated.generation)")
        }
        return token != nil
    }

    public func generation(_ instance: InstanceID) -> Int { cells[instance]?.generation ?? 0 }

    public func invalidate(_ instance: InstanceID) { cells.removeValue(forKey: instance) }
}
