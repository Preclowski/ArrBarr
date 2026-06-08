import Testing
import ArrCore
import MCP
@testable import ArrMCPServer

@Test func jsonValueToMCPValue_roundtripsScalars() {
    #expect(JSONValueBridge.toMCP(.string("hi")) == .string("hi"))
    #expect(JSONValueBridge.toMCP(.bool(true)) == .bool(true))
    #expect(JSONValueBridge.toMCP(.number(3)) == .double(3))
    #expect(JSONValueBridge.toMCP(.null) == .null)
}

@Test func jsonValueToMCPValue_nestsContainers() {
    let j = JSONValue.object(["xs": .array([.number(1), .string("a")])])
    #expect(JSONValueBridge.toMCP(j) == .object(["xs": .array([.double(1), .string("a")])]))
}

@Test func mcpValueToJSONValue_mapsIntAndDouble() {
    #expect(JSONValueBridge.toJSON(.int(7)) == .number(7))
    #expect(JSONValueBridge.toJSON(.double(2.5)) == .number(2.5))
    #expect(JSONValueBridge.toJSON(.object(["b": .bool(false)])) == .object(["b": .bool(false)]))
}

@Test func mcpArguments_convertToJSONObject() {
    let args: [String: Value] = ["query": .string("dune"), "year": .int(2021)]
    #expect(JSONValueBridge.argumentsToJSON(args) == .object(["query": .string("dune"), "year": .number(2021)]))
}
