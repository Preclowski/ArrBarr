# MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose ArrBarr's existing `LocalToolBackend` tools as an external MCP server over HTTP on macOS, so other MCP clients (Claude Desktop, etc.) can drive the user's media stack.

**Architecture:** A new macOS-only SPM package `Packages/ArrMCPServer` wraps ArrCore's `LocalToolBackend` behind the official `swift-sdk` MCP `Server` + `StatefulHTTPServerTransport`, hosted by a thin swift-nio HTTP listener (modeled on the SDK's own conformance `HTTPApp.swift`). The macOS `ArrBarr` target owns an `MCPServerController` that starts/stops the server from `ConfigStore` settings. `ArrCore` and the iOS target gain **no** new dependencies.

**Tech Stack:** Swift 6, swift-sdk (MCP) `0.11.0`, swift-nio, swift-log, Network/Security frameworks, SwiftUI (Settings pane).

**Reference material (read before starting):**
- Design spec: `docs/superpowers/specs/2026-06-08-mcp-server-design.md`
- SDK conformance HTTP host to adapt: clone `https://github.com/modelcontextprotocol/swift-sdk` and read `Sources/MCPConformance/Server/HTTPApp.swift` (the NIO↔`HTTPRequest`/`HTTPResponse` adapter template).
- SDK types: `Tool`, `Tool.Annotations`, `Tool.Content`, `Value`, `ListTools`, `CallTool`, `Server`, `StatefulHTTPServerTransport`, `HTTPRequest`/`HTTPResponse`, `HTTPRequestValidator`, `StandardValidationPipeline`, `OriginValidator`.

---

## File Structure

**New package `Packages/ArrMCPServer/`:**
- `Package.swift` — library `ArrMCPServer` (macOS 14) + test target; deps: ArrCore (path), swift-sdk, swift-nio.
- `Sources/ArrMCPServer/JSONValueBridge.swift` — `Value ⇄ JSONValue` conversion.
- `Sources/ArrMCPServer/ToolCatalogBridge.swift` — `ChatToolCatalog` → `[Tool]` with annotations, filtered by disabled set.
- `Sources/ArrMCPServer/BearerTokenValidator.swift` — `HTTPRequestValidator` for `Authorization: Bearer`.
- `Sources/ArrMCPServer/MCPCallRouter.swift` — builds the `Server`, registers `ListTools`/`CallTool` handlers, elicitation for destructive tools.
- `Sources/ArrMCPServer/NIOHTTPHost.swift` — swift-nio listener; NIO ⇄ `HTTPRequest`/`HTTPResponse`; routes to per-session `StatefulHTTPServerTransport`.
- `Sources/ArrMCPServer/MCPServerController.swift` — lifecycle/status; binds host:port, owns server + host.
- `Tests/ArrMCPServerTests/{JSONValueBridgeTests,ToolCatalogBridgeTests,BearerTokenValidatorTests,IntegrationTests}.swift`

**Modified in ArrCore (`Packages/ArrCore/Sources/ArrCore/`):**
- `Services/ConfigStore.swift` — default bind `127.0.0.1:8080`; replace `mcpAuthUsername`/`mcpAuthPassword` with `mcpAuthToken` (Keychain-backed); add `mcpServerStatus` published enum; migration.
- `Services/MCPTokenStore.swift` *(new)* — Keychain read/write/delete for the bearer token (Security framework, no external dep).
- `Models/MCPServerStatus.swift` *(new)* — `enum MCPServerStatus { stopped; running(url:); failed(message:) }`.
- `Views/MCPSettingsPane.swift` — token field (generate/copy/regenerate), status row + connect URL/snippet; bind-warning for non-localhost.

**Modified in macOS app (`ArrBarr/`):**
- `ArrBarr.entitlements` — add `com.apple.security.network.server`.
- `AppDelegate.swift` — own an `MCPServerController`, observe `ConfigStore`.
- `ArrBarr.xcodeproj/project.pbxproj` — add `ArrMCPServer` package dependency to the `ArrBarr` target.

---

## Phase 0 — Package scaffold & dependency

### Task 0: Create the `ArrMCPServer` package

**Files:**
- Create: `Packages/ArrMCPServer/Package.swift`
- Create: `Packages/ArrMCPServer/Sources/ArrMCPServer/Empty.swift`
- Create: `Packages/ArrMCPServer/Tests/ArrMCPServerTests/SmokeTests.swift`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArrMCPServer",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ArrMCPServer", targets: ["ArrMCPServer"])],
    dependencies: [
        .package(path: "../ArrCore"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.11.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "ArrMCPServer",
            dependencies: [
                .product(name: "ArrCore", package: "ArrCore"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ArrMCPServerTests",
            dependencies: ["ArrMCPServer"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Add placeholder sources**

`Sources/ArrMCPServer/Empty.swift`:
```swift
import ArrCore
import MCP
// Placeholder so the target compiles before real files land.
enum ArrMCPServerModule {}
```

`Tests/ArrMCPServerTests/SmokeTests.swift`:
```swift
import Testing
@testable import ArrMCPServer

@Test func moduleLoads() { #expect(true) }
```

- [ ] **Step 3: Resolve & build**

Run: `cd Packages/ArrMCPServer && swift build`
Expected: dependencies resolve (MCP, swift-nio, swift-system, swift-log, eventsource) and `Build complete!`. If resolution is slow the first time, that is expected.

- [ ] **Step 4: Run smoke test**

Run: `cd Packages/ArrMCPServer && swift test`
Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrMCPServer
git commit -m "feat(mcp): scaffold ArrMCPServer package (swift-sdk + swift-nio, macOS)"
```

---

## Phase 1 — Pure bridges (TDD, no networking)

### Task 1: `Value ⇄ JSONValue` bridge

`ArrCore.JSONValue` cases: `.null .bool(Bool) .number(Double) .string(String) .array([JSONValue]) .object([String:JSONValue])`.
`MCP.Value` cases: `.null .bool(Bool) .int(Int) .double(Double) .string(String) .data(mimeType:Data) .array([Value]) .object([String:Value])`.

**Files:**
- Create: `Packages/ArrMCPServer/Sources/ArrMCPServer/JSONValueBridge.swift`
- Test: `Packages/ArrMCPServer/Tests/ArrMCPServerTests/JSONValueBridgeTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
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
```

- [ ] **Step 2: Run, verify fail**

Run: `cd Packages/ArrMCPServer && swift test --filter JSONValueBridgeTests`
Expected: FAIL — `JSONValueBridge` undefined.

- [ ] **Step 3: Implement**

```swift
import ArrCore
import MCP
import Foundation

/// Converts between ArrCore's schema-less `JSONValue` and the MCP SDK's `Value`.
/// `JSONValue.number(Double)` maps to `Value.double`; `Value.int` folds back to
/// `.number`. `Value.data` has no JSON analogue and base64-encodes into a string.
enum JSONValueBridge {
    static func toMCP(_ v: JSONValue) -> Value {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .double(n)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(toMCP))
        case .object(let o): return .object(o.mapValues(toMCP))
        }
    }

    static func toJSON(_ v: Value) -> JSONValue {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .data(_, let d): return .string(d.base64EncodedString())
        case .array(let a): return .array(a.map(toJSON))
        case .object(let o): return .object(o.mapValues(toJSON))
        }
    }

    static func argumentsToJSON(_ args: [String: Value]?) -> JSONValue {
        .object((args ?? [:]).mapValues(toJSON))
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `cd Packages/ArrMCPServer && swift test --filter JSONValueBridgeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrMCPServer
git commit -m "feat(mcp): JSONValue <-> MCP Value bridge"
```

### Task 2: Tool-catalog → `[Tool]` bridge with annotations

`ChatToolCatalog.tools(...)` returns `[MCPTool]` (name, description, inputSchema: JSONValue). `MCPToolWhitelist.isDestructive(_ name:) -> Bool`. Disabled set from `ConfigStore.mcpDisabledTools`.

**Files:**
- Create: `Packages/ArrMCPServer/Sources/ArrMCPServer/ToolCatalogBridge.swift`
- Test: `Packages/ArrMCPServer/Tests/ArrMCPServerTests/ToolCatalogBridgeTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import ArrCore
import MCP
@testable import ArrMCPServer

@Test func bridge_mapsCatalogToSDKTools() {
    let tools = ToolCatalogBridge.sdkTools(
        catalog: ChatToolCatalog.tools(includeSonarr: true, includeRadarr: true),
        disabled: []
    )
    let names = Set(tools.map(\.name))
    #expect(names.contains("sonarr_get_series"))   // read-only
    #expect(names.contains("sonarr_search"))       // destructive
}

@Test func bridge_filtersDisabledTools() {
    let tools = ToolCatalogBridge.sdkTools(
        catalog: ChatToolCatalog.tools(includeSonarr: true, includeRadarr: true),
        disabled: ["sonarr_search"]
    )
    #expect(!tools.contains { $0.name == "sonarr_search" })
}

@Test func bridge_annotatesDestructiveVsReadOnly() {
    let tools = ToolCatalogBridge.sdkTools(
        catalog: ChatToolCatalog.tools(includeSonarr: true, includeRadarr: true),
        disabled: []
    )
    let search = tools.first { $0.name == "sonarr_search" }!
    let list = tools.first { $0.name == "sonarr_get_series" }!
    #expect(search.annotations.destructiveHint == true)
    #expect(search.annotations.readOnlyHint == false)
    #expect(list.annotations.readOnlyHint == true)
    #expect(list.annotations.destructiveHint == false)
}
```

- [ ] **Step 2: Run, verify fail**

Run: `cd Packages/ArrMCPServer && swift test --filter ToolCatalogBridgeTests`
Expected: FAIL — `ToolCatalogBridge` undefined.

- [ ] **Step 3: Implement**

```swift
import ArrCore
import MCP

/// Maps ArrCore's `ChatToolCatalog` entries into MCP SDK `Tool` values, applying
/// `MCPToolWhitelist` to set read-only / destructive hints and filtering the
/// user's disabled-tool opt-outs.
enum ToolCatalogBridge {
    static func sdkTools(catalog: [MCPTool], disabled: Set<String>) -> [Tool] {
        catalog.filter { !disabled.contains($0.name) }.map { t in
            let destructive = MCPToolWhitelist.isDestructive(t.name)
            return Tool(
                name: t.name,
                description: t.description,
                inputSchema: JSONValueBridge.toMCP(t.inputSchema),
                annotations: Tool.Annotations(
                    readOnlyHint: !destructive,
                    destructiveHint: destructive,
                    openWorldHint: t.name.contains("_search") || t.name.hasPrefix("tmdb_")
                )
            )
        }
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `cd Packages/ArrMCPServer && swift test --filter ToolCatalogBridgeTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrMCPServer
git commit -m "feat(mcp): catalog -> SDK Tool bridge with read-only/destructive annotations"
```

### Task 3: Bearer-token validator

`HTTPRequestValidator` protocol: `func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse?` (return `nil` = pass, non-nil = reject). `HTTPRequest.header("Authorization")`. Reject with `.error(statusCode: 401, .invalidRequest("Unauthorized"), extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"])`.

**Files:**
- Create: `Packages/ArrMCPServer/Sources/ArrMCPServer/BearerTokenValidator.swift`
- Test: `Packages/ArrMCPServer/Tests/ArrMCPServerTests/BearerTokenValidatorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import MCP
@testable import ArrMCPServer

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
    let resp = v.validate(req, context: ctx())
    #expect(resp?.statusCode == 401)
}

@Test func validator_rejectsWrongToken() {
    let v = BearerTokenValidator(token: "secret")
    let req = HTTPRequest(method: "POST", headers: ["Authorization": "Bearer nope"], body: nil, path: "/mcp")
    #expect(v.validate(req, context: ctx())?.statusCode == 401)
}
```

- [ ] **Step 2: Run, verify fail**

Run: `cd Packages/ArrMCPServer && swift test --filter BearerTokenValidatorTests`
Expected: FAIL — `BearerTokenValidator` undefined.

- [ ] **Step 3: Implement**

```swift
import MCP

/// Rejects requests lacking a matching `Authorization: Bearer <token>` header.
/// Place AFTER `OriginValidator.localhost()` in the pipeline.
struct BearerTokenValidator: HTTPRequestValidator {
    let token: String

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard let auth = request.header(HTTPHeaderName.authorization),
              auth.hasPrefix("Bearer "),
              String(auth.dropFirst("Bearer ".count)) == token else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized"),
                          extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"])
        }
        return nil
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `cd Packages/ArrMCPServer && swift test --filter BearerTokenValidatorTests`
Expected: PASS (3 tests). (If `HTTPValidationContext.init` arg labels differ at 0.11.0, adjust the test helper to match the SDK signature — read `HTTPRequestValidation.swift`.)

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrMCPServer
git commit -m "feat(mcp): Bearer token HTTPRequestValidator"
```

---

## Phase 2 — Server wiring (router + host + controller)

### Task 4: `MCPCallRouter` — Server + handlers + elicitation

Builds an MCP `Server`, registers `ListTools` (from `ToolCatalogBridge`) and `CallTool` (→ `LocalToolBackend.callTool`). For destructive tools, attempts `server.requestElicitation(...)` to confirm; if the client lacks the capability the call proceeds. `ToolCallOutput.text` → `CallTool.Result(content: [.text(text:annotations:_meta:)])`.

**Files:**
- Create: `Packages/ArrMCPServer/Sources/ArrMCPServer/MCPCallRouter.swift`
- Test: `Packages/ArrMCPServer/Tests/ArrMCPServerTests/IntegrationTests.swift` (added to in Task 7)

- [ ] **Step 1: Implement (no isolated unit test; covered by the integration test in Task 7)**

```swift
import ArrCore
import MCP
import Logging

/// Wires a configured `LocalToolBackend` + tool catalog into an MCP `Server`.
struct MCPCallRouter {
    let backend: LocalToolBackend
    let catalog: [MCPTool]
    let disabled: Set<String>
    let logger: Logger

    /// Build a fresh `Server` with handlers registered. One server per session.
    func makeServer() async -> Server {
        let server = Server(
            name: "ArrBarr",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolCatalogBridge.sdkTools(catalog: catalog, disabled: disabled))
        }

        await server.withMethodHandler(CallTool.self) { [backend, disabled, logger] params in
            let name = params.name
            guard !disabled.contains(name) else {
                return CallTool.Result(content: [.text(text: "Tool '\(name)' is disabled.",
                                                       annotations: nil, _meta: nil)], isError: true)
            }
            logger.info("tools/call", metadata: ["tool": .string(name)])

            // Server-side confirmation for destructive tools, where supported.
            if MCPToolWhitelist.isDestructive(name) {
                do {
                    let result = try await server.requestElicitation(
                        message: "Run \(name)? This may start downloads or change library state.",
                        requestedSchema: .object(properties: [:], required: []),
                        mode: nil
                    )
                    if case .decline = result.action {
                        return CallTool.Result(content: [.text(text: "Cancelled by user.",
                                                               annotations: nil, _meta: nil)], isError: false)
                    }
                } catch {
                    // Client lacks elicitation capability: proceed (destructiveHint already warned).
                    logger.debug("elicitation unsupported; proceeding", metadata: ["tool": .string(name)])
                }
            }

            do {
                let out = try await backend.callTool(
                    name: name,
                    arguments: JSONValueBridge.argumentsToJSON(params.arguments)
                )
                return CallTool.Result(content: [.text(text: out.text, annotations: nil, _meta: nil)],
                                       isError: false)
            } catch {
                return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                                       isError: true)
            }
        }

        return server
    }
}
```

> NOTE: `requestElicitation` arg labels and `result.action` enum case (`.decline`/`.reject`/`.cancel`) must be verified against `Sources/MCP/Server/Server.swift` and the `Elicitation` / `CreateElicitation.Result` types at the pinned version; adjust the `case` and `.object(properties:required:)` schema literal to match. If the schema factory differs, pass an empty object schema however the SDK expresses it.

- [ ] **Step 2: Build**

Run: `cd Packages/ArrMCPServer && swift build`
Expected: `Build complete!` (compile-only; behavior verified in Task 7).

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrMCPServer
git commit -m "feat(mcp): MCPCallRouter (ListTools/CallTool + destructive elicitation)"
```

### Task 5: `NIOHTTPHost` — swift-nio listener

Adapt the SDK conformance `HTTPApp.swift`. The host: binds `host:port`; for each HTTP request builds an `HTTPRequest`; on `initialize` creates a session (`StatefulHTTPServerTransport` + `Server` from `MCPCallRouter.makeServer()` + `server.start(transport:)`); routes subsequent requests by `Mcp-Session-Id` to `transport.handleRequest(_:)`; serializes `HTTPResponse` back to NIO, streaming the `.stream` (SSE) case.

**Files:**
- Create: `Packages/ArrMCPServer/Sources/ArrMCPServer/NIOHTTPHost.swift`

- [ ] **Step 1: Implement by adapting the conformance host**

Copy the structure of `Sources/MCPConformance/Server/HTTPApp.swift` from the SDK clone. Required adaptations:
- Constructor takes `host: String`, `port: Int`, `validationPipeline: any HTTPRequestValidationPipeline`, `logger: Logger`, and a `serverFactory: @Sendable (StatefulHTTPServerTransport) async throws -> Server` supplied by `MCPCallRouter`.
- Pass `validationPipeline` and `logger` into every `StatefulHTTPServerTransport(validationPipeline:logger:)`.
- Keep the NIO `ChannelHandler` that converts `HTTPRequestHead` + accumulated body → `HTTPRequest(method:headers:body:path:)` and `HTTPResponse` → NIO response, including the `.stream` (SSE: `Content-Type: text/event-stream`, write each `Data` chunk as it arrives, keep the channel open).
- Expose `func start() async throws` (bind) and `func stop() async` (close channel + disconnect transports).
- Bind via `ServerBootstrap(group:).bind(host:port:)`.

- [ ] **Step 2: Build**

Run: `cd Packages/ArrMCPServer && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrMCPServer
git commit -m "feat(mcp): swift-nio HTTP host (adapts SDK conformance HTTPApp)"
```

### Task 6: `MCPServerController` — lifecycle & status

Owns the host. `start(config:)` parses `host:port` from `ConfigStore.mcpHostPort`, builds the validation pipeline (`OriginValidator.localhost()` + `BearerTokenValidator` when `mcpRequireAuth`), constructs `NIOHTTPHost` with a `serverFactory` from `MCPCallRouter`, binds, and publishes status. `stop()` tears down. Status pushed back into ArrCore via a callback (set by AppDelegate to write `ConfigStore.mcpServerStatus`).

**Files:**
- Create: `Packages/ArrMCPServer/Sources/ArrMCPServer/MCPServerController.swift`

- [ ] **Step 1: Implement**

```swift
import ArrCore
import MCP
import Logging
import Foundation

public actor MCPServerController {
    public struct Config: Sendable {
        public let hostPort: String
        public let requireAuth: Bool
        public let token: String
        public let disabledTools: Set<String>
        public let backendInputs: BackendInputs
        public init(hostPort: String, requireAuth: Bool, token: String,
                    disabledTools: Set<String>, backendInputs: BackendInputs) {
            self.hostPort = hostPort; self.requireAuth = requireAuth; self.token = token
            self.disabledTools = disabledTools; self.backendInputs = backendInputs
        }
    }
    /// Snapshot of the arr/tmdb config needed to build LocalToolBackend + catalog.
    public struct BackendInputs: Sendable {
        public let sonarr, radarr, lidarr, whisparr: ServiceConfig
        public let aiKnowsAboutWhisparr: Bool
        public let tmdbApiKey: String
        public let downloadClients: DownloadClientConfigs
        public init(sonarr: ServiceConfig, radarr: ServiceConfig, lidarr: ServiceConfig,
                    whisparr: ServiceConfig, aiKnowsAboutWhisparr: Bool, tmdbApiKey: String,
                    downloadClients: DownloadClientConfigs) {
            self.sonarr = sonarr; self.radarr = radarr; self.lidarr = lidarr; self.whisparr = whisparr
            self.aiKnowsAboutWhisparr = aiKnowsAboutWhisparr; self.tmdbApiKey = tmdbApiKey
            self.downloadClients = downloadClients
        }
    }
    public enum Status: Sendable, Equatable {
        case stopped, running(url: String), failed(message: String)
    }

    private let logger = Logger(label: "arrbarr.mcp")
    private var host: NIOHTTPHost?
    private var onStatus: (@Sendable (Status) -> Void)?

    public init() {}
    public func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) { onStatus = handler }

    public func restart(with config: Config) async {
        await stop()
        let parts = config.hostPort.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            emit(.failed(message: "Invalid bind address: \(config.hostPort)")); return
        }
        let bindHost = String(parts[0])
        let i = config.backendInputs
        let backend = LocalToolBackend(sonarr: i.sonarr, radarr: i.radarr, lidarr: i.lidarr,
                                       whisparr: i.whisparr, aiKnowsAboutWhisparr: i.aiKnowsAboutWhisparr,
                                       tmdbApiKey: i.tmdbApiKey, downloadClients: i.downloadClients)
        let tmdbEnabled = !i.tmdbApiKey.isEmpty
        let catalog = ChatToolCatalog.tools(
            includeSonarr: i.sonarr.isConfigured, includeRadarr: i.radarr.isConfigured,
            includeLidarr: i.lidarr.isConfigured,
            includeWhisparr: i.whisparr.isConfigured && i.aiKnowsAboutWhisparr,
            includeTMDBMovies: tmdbEnabled && i.radarr.isConfigured,
            includeTMDBSeries: tmdbEnabled && i.sonarr.isConfigured)
        let router = MCPCallRouter(backend: backend, catalog: catalog,
                                   disabled: config.disabledTools, logger: logger)

        var validators: [any HTTPRequestValidator] = [
            OriginValidator.localhost(port: port), AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(), ProtocolVersionValidator(), SessionValidator(),
        ]
        if config.requireAuth { validators.insert(BearerTokenValidator(token: config.token), at: 1) }
        let pipeline = StandardValidationPipeline(validators: validators)

        let host = NIOHTTPHost(host: bindHost, port: port, validationPipeline: pipeline, logger: logger) { transport in
            await router.makeServer(transport: transport)
        }
        do {
            try await host.start()
            self.host = host
            emit(.running(url: "http://\(bindHost):\(port)/mcp"))
            logger.notice("MCP server started", metadata: ["url": .string("http://\(bindHost):\(port)/mcp")])
        } catch {
            emit(.failed(message: "\(error)"))
            logger.error("MCP server failed to start", metadata: ["error": .string("\(error)")])
        }
    }

    public func stop() async {
        await host?.stop(); host = nil
        emit(.stopped)
    }

    private func emit(_ s: Status) { onStatus?(s) }
}
```

> NOTE: `MCPCallRouter.makeServer` is adjusted here to accept the `transport` and call `server.start(transport:)` internally (the host passes each session's transport in via the factory). Align the two signatures when implementing.

- [ ] **Step 2: Build**

Run: `cd Packages/ArrMCPServer && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrMCPServer
git commit -m "feat(mcp): MCPServerController lifecycle + status"
```

### Task 7: End-to-end integration test

Start the controller on an ephemeral port (e.g. `127.0.0.1:0` is not supported by the address parse — use a fixed high port like `38080` and `requireAuth: false` to keep the test simple), then drive it with the SDK `Client` + `HTTPClientTransport`: `initialize`, `tools/list`, `tools/call` a read-only tool against a demo/empty backend.

**Files:**
- Modify: `Packages/ArrMCPServer/Tests/ArrMCPServerTests/IntegrationTests.swift`

- [ ] **Step 1: Write the test**

```swift
import Testing
import ArrCore
import MCP
import Foundation
@testable import ArrMCPServer

@Test func endToEnd_listAndCallReadOnlyTool() async throws {
    let controller = MCPServerController()
    let inputs = MCPServerController.BackendInputs(
        sonarr: .empty, radarr: .empty, lidarr: .empty, whisparr: .empty,
        aiKnowsAboutWhisparr: false, tmdbApiKey: "", downloadClients: .init())
    await controller.restart(with: .init(hostPort: "127.0.0.1:38080", requireAuth: false,
        token: "", disabledTools: [], backendInputs: inputs))
    defer { Task { await controller.stop() } }

    let client = Client(name: "test", version: "1")
    let transport = HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:38080/mcp")!)
    try await client.connect(transport: transport)
    let (tools, _) = try await client.listTools()
    #expect(tools.contains { $0.name == "health" })   // health is exposed whenever any arr/client present; assert a stable tool
    await client.disconnect()
}
```

- [ ] **Step 2: Run, verify it exercises the full path**

Run: `cd Packages/ArrMCPServer && swift test --filter IntegrationTests`
Expected: PASS. If `health` is gated out with all-empty configs, assert on whichever tool the empty-config catalog still exposes, or pass a minimally-configured `ServiceConfig` (enabled + baseURL + apiKey) so `includeSonarr` is true. Verify the gating in `ChatToolCatalog.tools`.

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrMCPServer
git commit -m "test(mcp): end-to-end SDK client -> server list/call"
```

---

## Phase 3 — ArrCore config: token, status, defaults

### Task 8: Keychain token store

`LegacyKeychain` only reads. Add a writer for the bearer token (Security framework; `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Services/MCPTokenStore.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/MCPTokenStoreTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import Testing
@testable import ArrCore

@Test func tokenStore_roundtrips() {
    MCPTokenStore.set("abc123")
    #expect(MCPTokenStore.read() == "abc123")
    MCPTokenStore.delete()
    #expect(MCPTokenStore.read() == nil)
}
```

- [ ] **Step 2: Run, verify fail**

Run: `cd Packages/ArrCore && swift test --filter MCPTokenStoreTests`
Expected: FAIL — `MCPTokenStore` undefined. (Keychain access in the test runner works on macOS; if the CI runner lacks a keychain, mark this test `.disabled` with a note.)

- [ ] **Step 3: Implement**

```swift
import Foundation
import Security

/// Keychain-backed storage for the MCP server's bearer token. Device-only,
/// unlocked-required — the one network-gating secret, kept out of UserDefaults.
public enum MCPTokenStore {
    private static let service = "com.preclowski.ArrBarr.mcp"
    private static let account = "bearer"

    public static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func set(_ token: String) {
        delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecValueData as String: Data(token.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    public static func delete() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    /// Generate a URL-safe random token.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `cd Packages/ArrCore && swift test --filter MCPTokenStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore
git commit -m "feat(mcp): Keychain-backed bearer token store"
```

### Task 9: ConfigStore — token field, status, default bind

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift`
- Create: `Packages/ArrCore/Sources/ArrCore/Models/MCPServerStatus.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/ConfigStoreTests.swift` (add cases)

- [ ] **Step 1: Add the status model**

`Models/MCPServerStatus.swift`:
```swift
import Foundation

public enum MCPServerStatus: Equatable, Sendable {
    case stopped
    case running(url: String)
    case failed(message: String)
}
```

- [ ] **Step 2: Write failing test for the new defaults/token**

```swift
@Test func mcp_defaultsToLocalhostBind() {
    let (defaults, _) = makeSuite()           // existing test helper in this file
    let store = ConfigStore(defaults: defaults)
    #expect(store.mcpHostPort == "127.0.0.1:8080")
}

@Test func mcp_tokenPersistsToKeychain() {
    let (defaults, _) = makeSuite()
    let store = ConfigStore(defaults: defaults)
    store.mcpAuthToken = "tok"
    #expect(MCPTokenStore.read() == "tok")
    MCPTokenStore.delete()
}
```

- [ ] **Step 3: Run, verify fail**

Run: `cd Packages/ArrCore && swift test --filter ConfigStoreTests`
Expected: FAIL — default is still `0.0.0.0:8080`; `mcpAuthToken` undefined.

- [ ] **Step 4: Modify ConfigStore**

- Change `mcpHostPort` default to `"127.0.0.1:8080"`.
- Remove `mcpAuthUsername`/`mcpAuthPassword` (`@Published` + keys + load + sink).
- Add:
```swift
@Published public var mcpAuthToken: String = MCPTokenStore.read() ?? ""
@Published public var mcpServerStatus: MCPServerStatus = .stopped
```
- In the init: load `mcpHostPort` with the new default; `mcpAuthToken` from `MCPTokenStore`.
- In `setupSinks` (the `$...sink` block): replace the username/password sinks with:
```swift
$mcpAuthToken.dropFirst().sink { val in
    if val.isEmpty { MCPTokenStore.delete() } else { MCPTokenStore.set(val) }
}.store(in: &cancellables)
```
- `mcpServerStatus` is set by the app (not persisted); no sink, no key.
- One-time migration: delete the now-unused `ArrBarr.mcpAuthUsername` / `ArrBarr.mcpAuthPassword` defaults keys.

- [ ] **Step 5: Run, verify pass**

Run: `cd Packages/ArrCore && swift test --filter ConfigStoreTests`
Expected: PASS.

- [ ] **Step 6: Build the whole package (catch MCPSettingsPane references to removed fields)**

Run: `cd Packages/ArrCore && swift build`
Expected: FAIL — `MCPSettingsPane` still references `mcpAuthUsername`/`mcpAuthPassword`. Fixed in Task 10.

- [ ] **Step 7: Commit (after Task 10 builds green; or stage together)**

### Task 10: MCPSettingsPane — token UI + status

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/MCPSettingsPane.swift`
- Localization: add new keys to `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`

- [ ] **Step 1: Replace the auth section** — remove username/password fields; add:
  - A token row: secure-ish display of `configStore.mcpAuthToken`, a **Generate** button (`configStore.mcpAuthToken = MCPTokenStore.generate()`), a **Copy** button, and a **Regenerate** confirmation.
  - Keep the `mcpRequireAuth` toggle; footer note that auth is recommended.
- [ ] **Step 2: Add a status row** bound to `configStore.mcpServerStatus`:
  - `.stopped` → grey dot "Stopped"; `.running(url)` → green dot + the URL + a Copy button + a copy-paste client snippet; `.failed(message)` → red dot + message.
- [ ] **Step 3: Bind-address warning** — if `mcpHostPort` does not start with `127.0.0.1` and `!mcpRequireAuth`, show an inline caution ("Exposed on the network without authentication").
- [ ] **Step 4: Add the new localization keys** (status labels, button titles, warnings) to `Localizable.xcstrings` with translations for `pl/de/es/fr` (run `swift test --filter LocalizationTests` to confirm completeness — it fails until every runtime-visible key is translated).
- [ ] **Step 5: Build + tests**

Run: `cd Packages/ArrCore && swift build && swift test`
Expected: `Build complete!`, all tests pass (incl. LocalizationTests).

- [ ] **Step 6: Commit**

```bash
git add Packages/ArrCore
git commit -m "feat(mcp): token UI + live server status in Settings MCP pane"
```

---

## Phase 4 — macOS app wiring

### Task 11: Entitlement + package dependency

**Files:**
- Modify: `ArrBarr/ArrBarr.entitlements`
- Modify: `ArrBarr.xcodeproj/project.pbxproj` (via Xcode UI)

- [ ] **Step 1: Add network.server entitlement**

Add to `ArrBarr/ArrBarr.entitlements`:
```xml
<key>com.apple.security.network.server</key>
<true/>
```

- [ ] **Step 2: Add the local package to the ArrBarr target**

In Xcode: File → Add Package Dependencies → Add Local… → select `Packages/ArrMCPServer` → add the `ArrMCPServer` library to the **ArrBarr** target only (not ArrBarriOS, not ArrBarrWidgets).

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -destination 'generic/platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ArrBarr/ArrBarr.entitlements ArrBarr.xcodeproj/project.pbxproj
git commit -m "build(mcp): network.server entitlement + ArrMCPServer dep on macOS target"
```

### Task 12: AppDelegate — own the controller, drive from ConfigStore

**Files:**
- Modify: `ArrBarr/AppDelegate.swift`

- [ ] **Step 1: Add the controller and wiring**

- Hold `private let mcpController = MCPServerController()`.
- On launch, set the status handler to write back to the shared `ConfigStore`:
```swift
await mcpController.setStatusHandler { status in
    Task { @MainActor in
        configStore.mcpServerStatus = MCPServerStatus(fromControllerStatus: status)
    }
}
```
(Define a small mapping between `MCPServerController.Status` and `ArrCore.MCPServerStatus` — identical shapes; add an initializer in the app target.)
- Observe `ConfigStore`: whenever `mcpEnabled`, `mcpHostPort`, `mcpRequireAuth`, `mcpAuthToken`, or `mcpDisabledTools` change, call either `mcpController.restart(with:)` (when enabled) or `mcpController.stop()`. Build `BackendInputs` from the same `ConfigStore` fields `ChatViewModelFactory` reads (sonarr/radarr/lidarr/whisparr `ServiceConfig`, `aiKnowsAboutWhisparr`, `tmdbApiKey`, download clients).
- Debounce rapid changes (e.g., 300ms) to avoid thrashing the listener while the user types a port.

- [ ] **Step 2: Build the app**

Run: `xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -destination 'generic/platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ArrBarr/AppDelegate.swift
git commit -m "feat(mcp): start/stop MCP server from ConfigStore in AppDelegate"
```

---

## Phase 5 — Manual verification

### Task 13: Live smoke test against a real client

- [ ] **Step 1: Build & relaunch** (per project convention)

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build/dd build
pkill -x ArrBarr 2>/dev/null; sleep 0.5; open -n build/dd/Build/Products/Debug/ArrBarr.app
```

- [ ] **Step 2:** In Settings → MCP: enable the server, generate a token, confirm the status row goes **running** with `http://127.0.0.1:8080/mcp`.
- [ ] **Step 3:** Verify with curl (expect 401 then 200):

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8080/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
# → 401 (no token)
curl ... -H 'Authorization: Bearer <token>' ...   # → 200
```

- [ ] **Step 4:** Add to Claude Desktop (or another MCP client) as an HTTP server with the bearer token; confirm `tools/list` shows the tools and a read-only call (e.g. `list_download_queue`) returns data. Confirm a destructive call (`sonarr_search`) triggers the client's confirm / elicitation.
- [ ] **Step 5:** Toggle the server off → status **stopped**, port closes (`curl` connection refused).
- [ ] **Step 6:** Log capture: `/usr/bin/log stream --level debug --predicate 'subsystem CONTAINS "arrbarr.mcp"'` shows start/stop/request/auth lines (swift-log → os.Logger bridge; if the bridge is deferred, swift-log prints to stdout instead).

---

## Self-review notes (gaps to watch during execution)

- **SDK API drift at 0.11.0:** the exact labels for `requestElicitation`, `CreateElicitation.Result.action` cases, the empty-object schema literal, `HTTPValidationContext.init`, and `OriginValidator.localhost(port:)` must be confirmed against the cloned source while implementing Tasks 3/4/6. Each such spot is flagged inline.
- **`MCPCallRouter.makeServer` signature** is referenced two ways (Task 4 vs Task 6) — settle on `makeServer(transport:)` that calls `server.start(transport:)` internally, and update Task 4's code accordingly.
- **swift-log → os.Logger bridge** (Task 13 step 6) is optional polish; if skipped, logs go to stdout. Not on the critical path.
- **Elicitation UX:** a client without elicitation silently proceeds on destructive tools (by design — `destructiveHint` still set). Confirmed acceptable in the spec.
