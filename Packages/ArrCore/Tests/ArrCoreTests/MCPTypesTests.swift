import Testing
import Foundation
@testable import ArrCore

@Suite("MCPTypes")
struct MCPTypesTests {
    @Test("decode tools/list response")
    func decodeToolsList() throws {
        let json = """
        {
          "jsonrpc": "2.0",
          "id": 1,
          "result": {
            "tools": [
              {
                "name": "sonarr_search",
                "description": "Search Sonarr for a series",
                "inputSchema": {
                  "type": "object",
                  "properties": {"query": {"type": "string"}},
                  "required": ["query"]
                }
              }
            ]
          }
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(JSONRPCResponse<ToolsListResult>.self, from: json)
        let tools = try #require(resp.result?.tools)
        #expect(tools.count == 1)
        #expect(tools[0].name == "sonarr_search")
        #expect(tools[0].description == "Search Sonarr for a series")
    }

    @Test("decode tools/call success")
    func decodeToolsCall() throws {
        let json = """
        {
          "jsonrpc": "2.0",
          "id": 2,
          "result": {
            "content": [{"type": "text", "text": "Found 3 results"}],
            "isError": false
          }
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(JSONRPCResponse<ToolsCallResult>.self, from: json)
        let r = try #require(resp.result)
        #expect(r.isError == false)
        #expect(r.content.first?.text == "Found 3 results")
    }

    @Test("decode error envelope")
    func decodeError() throws {
        let json = """
        {"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"Method not found"}}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(JSONRPCResponse<ToolsCallResult>.self, from: json)
        #expect((resp.result.map { _ in true } ?? false) == false)
        #expect(resp.error?.code == -32601)
        #expect(resp.error?.message == "Method not found")
    }

    @Test("JSONValue round-trips nested object")
    func jsonValueRoundTrip() throws {
        let original: JSONValue = .object([
            "n": .number(42),
            "s": .string("hi"),
            "arr": .array([.bool(true), .null]),
        ])
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(back == original)
    }

    @Test("encode JSONRPCRequest")
    func encodeRequest() throws {
        let req = JSONRPCRequest(id: 1, method: "tools/list", params: .object([:]))
        let data = try JSONEncoder().encode(req)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"jsonrpc\":\"2.0\""))
        #expect(s.contains("\"method\":\"tools\\/list\"") || s.contains("\"method\":\"tools/list\""))
    }
}
