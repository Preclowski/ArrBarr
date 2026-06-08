import Testing
import ArrCore
import MCP
@testable import ArrMCPServer

@Test func bridge_mapsCatalogToSDKTools() {
    let tools = ToolCatalogBridge.sdkTools(
        catalog: ChatToolCatalog.tools(includeSonarr: true, includeRadarr: true), disabled: [])
    let names = Set(tools.map(\.name))
    #expect(names.contains("sonarr_get_series"))
    #expect(names.contains("sonarr_search"))
}

@Test func bridge_filtersDisabledTools() {
    let tools = ToolCatalogBridge.sdkTools(
        catalog: ChatToolCatalog.tools(includeSonarr: true, includeRadarr: true), disabled: ["sonarr_search"])
    #expect(!tools.contains { $0.name == "sonarr_search" })
}

@Test func bridge_annotatesDestructiveVsReadOnly() {
    let tools = ToolCatalogBridge.sdkTools(
        catalog: ChatToolCatalog.tools(includeSonarr: true, includeRadarr: true), disabled: [])
    // `sonarr_search` is a metadata LOOKUP (surfaces add candidates; the user
    // taps a card to add). It does not hit indexers, so it is read-only.
    let lookup = tools.first { $0.name == "sonarr_search" }!
    // `sonarr_search_episodes` fires an indexer search that can start a grab —
    // genuinely destructive (matches MCPToolWhitelist's `_search_` infix rule).
    let indexerSearch = tools.first { $0.name == "sonarr_search_episodes" }!
    let list = tools.first { $0.name == "sonarr_get_series" }!
    #expect(lookup.annotations.readOnlyHint == true)
    #expect(lookup.annotations.destructiveHint == false)
    #expect(indexerSearch.annotations.destructiveHint == true)
    #expect(indexerSearch.annotations.readOnlyHint == false)
    #expect(list.annotations.readOnlyHint == true)
    #expect(list.annotations.destructiveHint == false)
}
