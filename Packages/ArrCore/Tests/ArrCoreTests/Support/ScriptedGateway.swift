import Foundation
import MediaKit
import Testing
@testable import ArrCore

/// A transport answering from a closure, so a suite's traffic never leaves its own gateway.
final class ScriptedTransport: Transport, @unchecked Sendable {
    struct Answer: Sendable {
        var status = 200
        var body = Data("[]".utf8)
        init(status: Int = 200, body: Data = Data("[]".utf8)) { self.status = status; self.body = body }
        init(status: Int = 200, _ text: String) { self.status = status; body = Data(text.utf8) }
    }

    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private let respond: @Sendable (HTTPRequest) async throws -> Answer

    init(_ respond: @escaping @Sendable (HTTPRequest) async throws -> Answer) { self.respond = respond }

    var requests: [HTTPRequest] { lock.withLock { recorded } }
    func reset() { lock.withLock { recorded = [] } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        let answer = try await respond(request)
        return HTTPResponse(status: answer.status, headers: ["Content-Type": "application/json"], body: answer.body)
    }
}

extension HTTPRequest {
    var bodyData: Data? { if case let .bytes(data, _) = body { data } else { nil } }
    var jsonBody: [String: Any] { bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
}

extension ServiceGateway {
    /// An empty-profile gateway on `transport`; it never becomes the process-wide one.
    static func scripted(_ transport: any Transport) async -> ServiceGateway {
        await MainActor.run {
            let hadCurrent = current != nil
            let store = ConfigStore(defaults: TestDefaults.suite("ArrCoreTests.scripted"), secrets: InMemorySecretStore())
            let gateway = ServiceGateway(configStore: store, demo: false, transport: transport)
            // Credentials for adopted configs resolve through the store's gateway.
            store.gateway = gateway
            if !hadCurrent { current = nil }
            return gateway
        }
    }
}

/// Runs each test of a suite with facades resolving a fresh gateway on `transport`.
struct ScriptedGatewayTrait: SuiteTrait, TestTrait, TestScoping {
    let transport: any Transport
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard !test.isSuite else { return try await function() }
        let gateway = await ServiceGateway.scripted(transport)
        try await ServiceGateway.$override.withValue(gateway) { try await function() }
    }
}

extension Trait where Self == ScriptedGatewayTrait {
    static func gateway(_ transport: any Transport) -> Self { ScriptedGatewayTrait(transport: transport) }
}
