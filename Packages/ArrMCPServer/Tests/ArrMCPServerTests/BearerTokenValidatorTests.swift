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
