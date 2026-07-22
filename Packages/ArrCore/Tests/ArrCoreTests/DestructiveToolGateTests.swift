import Testing
@testable import ArrCore

/// The destructive-tool confirmation used to be re-implemented at each call
/// site (chat's OpenAI path, chat's Foundation Models path, the MCP router), so
/// a call site that forgot it — or a new one added later — bypassed the gate
/// entirely and let an unattended LLM start downloads. It now lives in
/// `LocalToolBackend.callTool`, the single choke point every caller goes
/// through, and the allowlist behind it fails closed.
///
/// Every test here runs with **no network stubbed and no arr configured**: if
/// the gate ever stops holding, the call reaches `run` and returns a
/// `ToolCallOutput` instead of throwing, which is precisely what these assert
/// against.
@Suite("Destructive-tool gate")
struct DestructiveToolGateTests {

    /// Whisparr and TMDB are switched ON so the two prefix guards in `callTool`
    /// can't short-circuit a tool before it reaches the gate — otherwise this
    /// suite would silently stop covering any future `whisparr_*` mutation.
    /// Every arr is left unconfigured: nothing may touch the network.
    private func backend() -> LocalToolBackend {
        LocalToolBackend(
            sonarr: .empty, radarr: .empty, lidarr: .empty, whisparr: .empty,
            aiKnowsAboutWhisparr: true, tmdbApiKey: "tmdb-key"
        )
    }

    private var destructiveCatalogTools: [String] {
        ChatToolCatalog.allToolNames.filter { MCPToolWhitelist.isDestructive($0) }
    }

    /// The choke point, asserted across the *whole* catalog rather than one
    /// sample tool: no destructive tool runs when nobody can be asked.
    @Test("No destructive catalog tool runs without a confirmation handler")
    func everyDestructiveToolRefusesUnconfirmed() async throws {
        let sut = backend()
        // Sanity: an empty list would make the loop below vacuously pass.
        #expect(!destructiveCatalogTools.isEmpty)

        for name in destructiveCatalogTools {
            await #expect(throws: LocalToolError.confirmationUnavailable(name)) {
                _ = try await sut.callTool(name: name, arguments: .object([:]))
            }
        }
    }

    /// Fail-closed is the whole design: the allowlist names what may run
    /// unattended, so anything it doesn't name — a tool we ship next month, a
    /// typo, a name an MCP client invented — is gated by default.
    @Test("An unrecognised tool name is gated by default", arguments: [
        "queue_purge",              // plausible future tool, no `_add_`/`_delete_` in the name
        "sonarr_blocklist_release", // ditto
        "sonarr_add_series",        // a tool we deliberately don't ship
        "radarr_get_calender",      // a typo of a genuinely read-only tool
        "",                         // degenerate input
    ])
    func unknownNamesAreGated(_ name: String) {
        #expect(MCPToolWhitelist.isDestructive(name))
    }

    /// …and a name outside the catalog can't be executed by answering "yes"
    /// either — it is rejected before a pointless confirmation is raised.
    @Test("A tool outside the catalog never runs, confirmed or not")
    func unknownToolNeverRuns() async throws {
        let sut = backend()
        let approve: ToolConfirmationHandler = { .approved($0.arguments) }

        await #expect(throws: LocalToolError.unknownTool("queue_purge")) {
            _ = try await sut.callTool(name: "queue_purge", arguments: .object([:]))
        }
        await #expect(throws: LocalToolError.unknownTool("queue_purge")) {
            try await ToolConfirmationContext.$handler.withValue(approve) {
                _ = try await sut.callTool(name: "queue_purge", arguments: .object([:]))
            }
        }
    }

    /// The gated set, spelled out. Widening the allowlist is a security
    /// decision, so it has to be a deliberate edit here too — a tool that
    /// quietly moves from "confirm first" to "runs unattended" is exactly the
    /// change that must not slip through review.
    @Test("Exactly the mutating tools are gated")
    func gatedSetIsTheMutatingTools() {
        let expected: Set<String> = [
            "sonarr_monitor_season",  // flips monitoring AND fires a season search
            "lidarr_monitor_album",   // ditto, album search
            "sonarr_search_episodes", // manual indexer searches — they grab releases
            "radarr_search_movie",
            "lidarr_search_album",
        ]
        #expect(Set(destructiveCatalogTools) == expected)
    }

    // MARK: - The three answers

    @Test("Declining refuses the call and says so")
    func declineRefuses() async throws {
        let sut = backend()
        let decline: ToolConfirmationHandler = { _ in .declined }

        await #expect(throws: LocalToolError.confirmationDeclined("radarr_search_movie")) {
            try await ToolConfirmationContext.$handler.withValue(decline) {
                _ = try await sut.callTool(
                    name: "radarr_search_movie", arguments: .object(["movieId": .number(7)]))
            }
        }
    }

    /// A client that *has* a handler but reports it cannot ask (an MCP client
    /// that never advertised elicitation) is not the same as a user saying no,
    /// but the outcome for the tool is identical: it does not run.
    @Test("A handler that cannot ask still blocks the call")
    func unavailableRefuses() async throws {
        let sut = backend()
        let cannotAsk: ToolConfirmationHandler = { _ in .unavailable }

        await #expect(throws: LocalToolError.confirmationUnavailable("radarr_search_movie")) {
            try await ToolConfirmationContext.$handler.withValue(cannotAsk) {
                _ = try await sut.callTool(
                    name: "radarr_search_movie", arguments: .object(["movieId": .number(7)]))
            }
        }
    }

    /// Gating everything would be safe and useless — approval has to actually
    /// reach the implementation. Radarr is unconfigured, so the canned
    /// "not configured" line is proof the call got past the gate without any
    /// network being involved.
    @Test("Approval runs the tool")
    func approvalRuns() async throws {
        let sut = backend()
        let approve: ToolConfirmationHandler = { .approved($0.arguments) }

        let output = try await ToolConfirmationContext.$handler.withValue(approve) {
            try await sut.callTool(
                name: "radarr_search_movie", arguments: .object(["movieId": .number(7)]))
        }
        #expect(output.text == "Radarr is not configured.")
    }

    /// The handler travels as a task-local, so the obvious failure mode is one
    /// binding blessing later calls. It must expire with its scope.
    @Test("Approval does not leak past the binding that granted it")
    func approvalDoesNotLeak() async throws {
        let sut = backend()
        let approve: ToolConfirmationHandler = { .approved($0.arguments) }

        _ = try await ToolConfirmationContext.$handler.withValue(approve) {
            try await sut.callTool(
                name: "radarr_search_movie", arguments: .object(["movieId": .number(7)]))
        }

        await #expect(throws: LocalToolError.confirmationUnavailable("radarr_search_movie")) {
            _ = try await sut.callTool(
                name: "radarr_search_movie", arguments: .object(["movieId": .number(7)]))
        }
    }

    /// The confirmation carries the arguments, so a confirm UI can hand back
    /// edited ones — and what it hands back is what runs.
    @Test("The arguments the user approved are the ones that run")
    func approvedArgumentsAreUsed() async throws {
        let sut = backend()
        // Swap in a movieId of 0, which `radarr_search_movie` rejects before it
        // even looks at the config — a reply only reachable via the approved
        // arguments, not the requested ones.
        let rewrite: ToolConfirmationHandler = { _ in .approved(.object(["movieId": .number(0)])) }

        let output = try await ToolConfirmationContext.$handler.withValue(rewrite) {
            try await sut.callTool(
                name: "radarr_search_movie", arguments: .object(["movieId": .number(7)]))
        }
        #expect(output.text.contains("Need a valid movieId"))
    }

    /// Read-only tools must stay reachable with nobody watching — an MCP client
    /// running unattended is meant to get the whole read surface.
    @Test("Read-only catalog tools are not gated")
    func readOnlyToolsAreNotGated() {
        let readOnly = ChatToolCatalog.allToolNames.filter { !MCPToolWhitelist.isDestructive($0) }
        #expect(readOnly.contains("sonarr_search"))
        #expect(readOnly.contains("get_calendar"))
        #expect(readOnly.contains("list_download_queue"))
        #expect(readOnly.count == ChatToolCatalog.allToolNames.count - destructiveCatalogTools.count)
    }
}
