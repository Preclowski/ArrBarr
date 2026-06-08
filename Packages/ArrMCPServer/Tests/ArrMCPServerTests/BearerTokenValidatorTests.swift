import Testing
import MCP
@testable import ArrMCPServer

// NOTE: swift-sdk 0.12.1 ships its own public `MCP.BearerTokenValidator`, which
// collides with the type under test. Fully qualify with the module name so the
// unqualified symbol resolves to our internal validator rather than the SDK's.
private typealias BearerTokenValidator = ArrMCPServer.BearerTokenValidator

private func ctx() -> HTTPValidationContext {
    HTTPValidationContext(httpMethod: "POST", sessionID: nil, isInitializationRequest: true,
                          supportedProtocolVersions: ["2025-06-18"])
}

@Test func validator_passesCorrectToken() {
    let v = BearerTokenValidator(token: "secret")
    let req = HTTPRequest(method: "POST", headers: ["Authorization": "Bearer secret"], body: nil, path: "/mcp")
    #expect(v.validate(req, context: ctx()) == nil)
}
@Test func validator_rejectsMissingHeader() {
    let v = BearerTokenValidator(token: "secret")
    let req = HTTPRequest(method: "POST", headers: [:], body: nil, path: "/mcp")
    #expect(v.validate(req, context: ctx())?.statusCode == 401)
}
@Test func validator_rejectsWrongToken() {
    let v = BearerTokenValidator(token: "secret")
    let req = HTTPRequest(method: "POST", headers: ["Authorization": "Bearer nope"], body: nil, path: "/mcp")
    #expect(v.validate(req, context: ctx())?.statusCode == 401)
}
