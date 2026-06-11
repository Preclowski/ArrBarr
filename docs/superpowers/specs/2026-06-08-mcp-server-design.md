# MCP Server — Design

**Date:** 2026-06-08
**Status:** Approved (pending spec review)
**Scope:** Expose ArrBarr's existing in-app tools as an external MCP server over HTTP, so other apps (Claude Desktop, other MCP clients) can drive Sonarr/Radarr/Lidarr/Whisparr through ArrBarr.

## 1. Goal & context

ArrBarr already has a complete tool layer for its in-app LLM chat:

- `ChatToolCatalog` — single source of truth for 26 tools (names, descriptions, JSON schemas, per-tool directory for the Settings pane).
- `LocalToolBackend` (`ToolBackend` protocol: `listTools()` / `callTool(name:arguments:)`) — in-process execution against ArrCore's arr clients.
- `MCPTypes` (`MCPTool`, `JSONValue`), `MCPToolWhitelist` (destructive-tool classification).
- A **Settings → MCP pane** plus persisted (currently UI-only "mock") config in `ConfigStore`: `mcpEnabled`, `mcpHostPort`, auth fields, `mcpDisabledTools`.

This shape is already MCP-shaped. The only missing piece is a **real HTTP/JSON-RPC transport** wrapping `LocalToolBackend`. This design wires that up using the official Swift MCP SDK.

## 2. Decisions (locked)

| Decision | Choice |
|---|---|
| Transport library | Official `modelcontextprotocol/swift-sdk` (MCP), pinned |
| HTTP host | Raw **swift-nio** adapter, modeled on the SDK's own `MCPConformance` `HTTPApp.swift` |
| MCP transport | `StatefulHTTPServerTransport` (SSE; required for elicitation / server→client) |
| Bind default | `127.0.0.1:8080` (localhost only; LAN requires explicit `0.0.0.0`) |
| Auth | **Bearer token** (`Authorization: Bearer <token>`), token in Keychain |
| Platform | **macOS only**, never iOS (server runs in-process while the menu-bar app lives) |
| Tool exposure | **All tools**, annotated `readOnlyHint`/`destructiveHint`; **elicitation** as server-side backup confirm for destructive tools |
| Dependency boundary | SDK + swift-nio live **only in the macOS `ArrBarr` target**; `ArrCore` stays zero-dependency |

## 3. Architecture

```
External MCP client (Claude Desktop, …)
        │  HTTP/1.1 + SSE on 127.0.0.1:8080, Authorization: Bearer <token>
        ▼
NIO HTTP host  (ArrBarr target)            ── adapts NIO ⇄ HTTPRequest/HTTPResponse
        │  transport.handleRequest(HTTPRequest) → HTTPResponse (.data | .stream)
        ▼
StatefulHTTPServerTransport  (MCP SDK)     ── sessions, SSE, validation pipeline (auth)
        │  ListTools / CallTool method handlers
        ▼
MCP↔ArrCore bridge  (ArrBarr target)       ── Value⇄JSONValue, catalog→Tool, annotations, elicitation
        │  LocalToolBackend.callTool(name:arguments:)
        ▼
ArrCore: LocalToolBackend → Sonarr/Radarr/Lidarr/Whisparr/TMDB clients → arr APIs
```

`ArrCore` is unchanged: the server consumes its existing public API (`LocalToolBackend`, `ChatToolCatalog`, `ConfigStore`, `MCPToolWhitelist`). The in-app chat path is untouched and keeps using `MCPTypes`/`ToolCallOutput.rich`. Over MCP only `ToolCallOutput.text` is returned (rich UI payloads are dropped — unavoidable for an external client).

## 4. Components (macOS `ArrBarr` target)

### 4.1 `MCPServerController` (actor / `@MainActor`-observed)
Lifecycle owner. Observes `ConfigStore` (`mcpEnabled`, `mcpHostPort`, token, `mcpRequireAuth`, `mcpDisabledTools`).
- On enable / config change: build the validation pipeline, construct the NIO host bound to the configured host:port, start accepting connections.
- On disable: stop the host, drain sessions.
- Publishes `Status`: `.stopped`, `.running(url:)`, `.error(message:)` (e.g. port in use, bind failure) for the Settings pane.
- Restart on relevant config changes (port, token, bind).

### 4.2 NIO HTTP host
Thin adapter modeled on the SDK conformance `HTTPApp.swift`:
- `ServerBootstrap` bound to `host:port`.
- Per session (`Mcp-Session-Id`) a `StatefulHTTPServerTransport`; new sessions created on `initialize`.
- Channel handler converts NIO `HTTPRequestHead`/body ⇄ SDK `HTTPRequest`, and `HTTPResponse` ⇄ NIO response — including the `.stream` (SSE) case (write `text/event-stream` chunks, keep channel open).
- Routes each request to the matching session's `transport.handleRequest(_:)`.

### 4.3 MCP↔ArrCore bridge
- **`ListTools` handler:** `ChatToolCatalog.tools(...)` minus `mcpDisabledTools` → SDK `Tool`, with `annotations` (`readOnlyHint = !isDestructive`, `destructiveHint = isDestructive`, `openWorldHint` for search tools), schema mapped from `MCPTool.inputSchema`.
- **`CallTool` handler:** SDK `Value` arguments → `JSONValue` (adapter) → `LocalToolBackend.callTool` → `ToolCallOutput.text` wrapped as `CallTool.Result(content: [.text(...)])`. Errors → `isError: true`.
- **Elicitation:** for a `destructive` tool, if the client advertised the `elicitation` capability, send an elicitation request ("Confirm: run `<tool>` with `<args>`?") before executing; on decline return a cancelled result. If the client lacks elicitation, proceed (the `destructiveHint` annotation already signals risk).
- **`Server` capabilities:** `tools` (with `listChanged`); register a `tools/list_changed` notification when `mcpDisabledTools` changes while running (nice-to-have).

### 4.4 Auth — `BearerTokenValidator`
`HTTPRequestValidator` (~10 lines): require `Authorization: Bearer <token>` matching the stored token; else `401` with `WWW-Authenticate`. Composed in `StandardValidationPipeline` after `OriginValidator.localhost(port:)`. Auth is enforced when `mcpRequireAuth` is on (recommended/default on); when off, only origin validation applies.

### 4.5 Logging (swift-log, used actively)
- `Logger(label: "arrbarr.mcp")` injected into `StatefulHTTPServerTransport(logger:)`, the NIO host, and `MCPServerController`.
- Structured logs: server start/stop/bind, each request (method, session, tool name), auth failures, tool errors, elicitation outcomes.
- A swift-log → `os.Logger` backend so MCP logs surface in `log stream` alongside the rest of ArrBarr (consistent with existing log-capture workflow).

## 5. Config & UI changes

### 5.1 `ConfigStore` (ArrCore)
- `mcpHostPort` default → `127.0.0.1:8080` (was `0.0.0.0:8080`).
- Replace `mcpAuthUsername`/`mcpAuthPassword` with a single **`mcpAuthToken`** (Bearer); store the secret in **Keychain** (`KeychainStore`), keep only a presence flag / non-secret state in defaults. One-time migration drops the old user/pass keys.
- Keep `mcpEnabled`, `mcpRequireAuth` (default **on**), `mcpDisabledTools`.

### 5.2 Settings → MCP pane (macOS)
- **Token field:** generate / copy / regenerate (writes Keychain).
- **Bind field:** host:port, default `127.0.0.1:8080`; inline warning when set to `0.0.0.0` without auth.
- **Status row:** stopped / running / error, with the live connect URL (`http://127.0.0.1:8080/mcp`) and a **copy-paste client config snippet** (Claude Desktop style).
- Existing per-tool toggles drive `mcpDisabledTools`.
- iOS shows a "macOS only" placeholder for the pane.

### 5.3 Entitlements
- Add `com.apple.security.network.server` to `ArrBarr.entitlements` (macOS app currently has only `network.client`).

## 6. Error handling

- **Bind failure / port in use:** `MCPServerController` surfaces `.error(message:)`; the toggle reflects "failed", pane shows the reason; no crash.
- **Auth failure:** `401` + `WWW-Authenticate`, logged at `notice`.
- **Tool error:** `LocalToolBackend` throw → `CallTool.Result(isError: true, content: [.text(message)])`; never crashes the session.
- **Unknown tool / disabled tool:** not advertised; if called anyway → JSON-RPC method/params error.
- **Client without elicitation calling a destructive tool:** proceed (annotation-only); never hang waiting for a confirm the client can't show.

## 7. Testing

- **Adapter:** `Value`⇄`JSONValue` round-trip; `MCPTool.inputSchema` → SDK schema; annotation mapping from `MCPToolWhitelist`.
- **Catalog filtering:** `mcpDisabledTools` removes tools from `ListTools`.
- **CallTool parity:** dispatch matches `LocalToolBackend` for a representative read + write tool (demo-mode backend, no live arrs).
- **Auth:** missing / wrong / correct Bearer → 401 / 401 / pass; origin validation rejects non-localhost Origin.
- **Integration:** start the server on an ephemeral port; drive it with the SDK's `Client` + `HTTPClientTransport` → `initialize`, `tools/list`, `tools/call`; assert results. Elicitation path with a stub client that accepts/declines.
- **Lifecycle:** enable→running, disable→stopped, port-in-use→error surfaced.

## 8. Dependencies (macOS `ArrBarr` target only)

- `modelcontextprotocol/swift-sdk` (MCP) — pinned (`.exact` or narrow range, since pre-1.0) → transitively `swift-system`, `swift-log`, `eventsource`.
- `apple/swift-nio` (`NIOCore`, `NIOPosix`, `NIOHTTP1`) for the HTTP host.
- `ArrCore` and the iOS target gain **no** new dependencies.

## 9. Out of scope (YAGNI)

- iOS server (no background hosting).
- stdio transport (HTTP only, per decision).
- MCP `resources` / `prompts` / `sampling` (tools-only surface).
- LaunchAgent / running while the app is quit (menu-bar app is always running on macOS).
- Sharing the `rich` UI payload over MCP (text-only by protocol).
- OAuth flow (single static Bearer token is sufficient for a local, user-controlled server).

## 10. Open items / spikes folded in

- Confirm the SDK's `Tool.annotations` field names/shape at the pinned version (readOnly/destructive/openWorld hints) when wiring `ListTools`.
- Confirm the elicitation request/response API shape on `Server` at the pinned version.
- Decide the NIO host: adapt the conformance `HTTPApp.swift` directly vs. a trimmed reimplementation (both are ~200 lines; start from the conformance pattern).
