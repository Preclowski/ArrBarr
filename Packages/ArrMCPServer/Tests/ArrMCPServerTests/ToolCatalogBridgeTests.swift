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
    let search = tools.first { $0.name == "sonarr_search" }!
    let list = tools.first { $0.name == "sonarr_get_series" }!
    #expect(search.annotations.destructiveHint == true)
    #expect(search.annotations.readOnlyHint == false)
    #expect(list.annotations.readOnlyHint == true)
    #expect(list.annotations.destructiveHint == false)
}
