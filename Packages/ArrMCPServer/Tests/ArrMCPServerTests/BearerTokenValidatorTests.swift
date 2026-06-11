import Testing
import MCP
@testable import ArrMCPServer

private func ctx() -> HTTPValidationContext {
    HTTPValidationContext(httpMethod: "POST", sessionID: nil, isInitializationRequest: true,
                          supportedProtocolVersions: ["2025-06-18"])
}

@Test func validator_passesCorrectToken() {
    let v = StaticBearerValidator(token: "secret")
    let req = HTTPRequest(method: "POST", headers: ["Authorization": "Bearer secret"], body: nil, path: "/mcp")
    #expect(v.validate(req, context: ctx()) == nil)
}

@Test func validator_rejectsMissingHeader() {
    let v = StaticBearerValidator(token: "secret")
    let req = HTTPRequest(method: "POST", headers: [:], body: nil, path: "/mcp")
    #expect(v.validate(req, context: ctx())?.statusCode == 401)
}

@Test func validator_rejectsWrongToken() {
    let v = StaticBearerValidator(token: "secret")
    let req = HTTPRequest(method: "POST", headers: ["Authorization": "Bearer nope"], body: nil, path: "/mcp")
    #expect(v.validate(req, context: ctx())?.statusCode == 401)
}

@Test func validator_emptyConfiguredTokenFailsClosed() {
    // Auth on but no token minted yet: a forged empty "Bearer " header must
    // not slip through as an empty-equals-empty match.
    let v = StaticBearerValidator(token: "")
    let forged = HTTPRequest(method: "POST", headers: ["Authorization": "Bearer "], body: nil, path: "/mcp")
    #expect(v.validate(forged, context: ctx())?.statusCode == 401)
    let plain = HTTPRequest(method: "POST", headers: [:], body: nil, path: "/mcp")
    #expect(v.validate(plain, context: ctx())?.statusCode == 401)
}

@Test func validator_rejectsTokenPrefix() {
    let v = StaticBearerValidator(token: "secret")
    let req = HTTPRequest(method: "POST", headers: ["Authorization": "Bearer secre"], body: nil, path: "/mcp")
    #expect(v.validate(req, context: ctx())?.statusCode == 401)
}
