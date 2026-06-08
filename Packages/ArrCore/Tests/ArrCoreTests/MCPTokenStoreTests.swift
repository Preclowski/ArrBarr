import Testing
@testable import ArrCore

@Test func tokenStore_roundtrips() {
    MCPTokenStore.set("abc123")
    #expect(MCPTokenStore.read() == "abc123")
    MCPTokenStore.delete()
    #expect(MCPTokenStore.read() == nil)
}

@Test func tokenStore_generatesUrlSafeToken() {
    let t = MCPTokenStore.generate()
    #expect(!t.isEmpty)
    #expect(!t.contains("+"))
    #expect(!t.contains("/"))
    #expect(!t.contains("="))
}
