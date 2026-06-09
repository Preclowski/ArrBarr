import Foundation

public struct OpenAIProvider: LLMProvider {
    private let config: OpenAIConfig
    private let session: URLSession
    /// Human-readable language the assistant should reply in by default
    /// (e.g. "Polish"). Sourced from the app's language setting.
    private let replyLanguage: String

    public init(config: OpenAIConfig, session: URLSession = .shared, replyLanguage: String = "English") {
        self.config = config
        self.session = session
        self.replyLanguage = replyLanguage
    }

    public var isAvailable: Bool { config.isConfigured }

    /// Lightweight key/endpoint check: `GET {baseURL}/models` with the Bearer
    /// key. 200 means the key + base URL are valid; throws otherwise. Used by the
    /// Settings "Test key" button.
    public func testConnection() async throws {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else { throw OpenAIError.empty }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.empty }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    public func respond(prompt: String, tools: [LLMTool], history: [ChatMessage]) async throws -> LLMResponse {
        let body = Self.buildRequestBody(
            model: config.model,
            prompt: prompt,
            tools: tools,
            history: history,
            replyLanguage: replyLanguage
        )
        let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("https://github.com/Preclowski/ArrBarr", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("ArrBarr", forHTTPHeaderField: "X-Title")
        // LLM completions can take a while (slow/free endpoints, reasoning
        // models, multi-round tool loops). The 60s URLSession default was too
        // tight and surfaced as "chat timed out"; give it generous headroom.
        req.timeoutInterval = 120
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        req.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.empty }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIError.http(status: http.statusCode, body: body)
        }
        let decoded: ChatCompletionsResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        } catch {
            throw OpenAIError.decoding(String(describing: error))
        }
        guard let choice = decoded.choices.first else { throw OpenAIError.empty }
        let text = choice.message.content ?? ""
        let toolCalls: [ToolCall] = (choice.message.tool_calls ?? []).map { call in
            let argsValue: JSONValue
            if let data = call.function.arguments.data(using: .utf8),
               let v = try? JSONDecoder().decode(JSONValue.self, from: data) {
                argsValue = v
            } else {
                argsValue = .object([:])
            }
            return ToolCall(id: call.id, name: call.function.name, arguments: argsValue)
        }
        return LLMResponse(text: text, toolCalls: toolCalls, toolResults: nil)
    }

    // MARK: - Request building (pure — tested independently)

    static func buildRequestBody(model: String, prompt: String, tools: [LLMTool], history: [ChatMessage], replyLanguage: String = "English") -> ChatCompletionsRequest {
        let arrs = SystemPromptComposer.arrsClause(tools: tools)
        let systemMessage = ChatCompletionsRequest.Message(
            role: "system",
            content: """
            You are ArrBarr's in-app assistant for \(arrs) — and a film buff at heart.
            You speak concisely but with real passion for film and TV. You run your own homelab on the same *arr stack, so you talk to the user as a fellow self-hoster: when it helps, you share a hard-won tip on quality profiles, custom formats or release groups — never lecturing. Passion shows in your word choice, not your length: keep it short.
            Always reply in the same language as the user's latest message — this takes priority. Only when their language is genuinely unclear, default to \(replyLanguage). Keep media titles exactly as the user wrote them.
            Call a tool when the request needs server data or an action. Otherwise just answer.
            Only use tools from the provided list.

            Replies render as GitHub-flavored Markdown, so format for clarity.
            You MAY use:
              • Markdown tables — ideal for comparing a few titles/specs
                side by side (e.g. quality, size, score across releases)
              • bullet or numbered lists
              • inline emphasis: **bold**, *italic*, `code`, [link](url)
              • headings sparingly (## only, for a longer structured answer)
            Avoid emoji. Keep replies short — usually one short paragraph; reach
            for a table or list only when it genuinely helps (comparisons or
            multi-field data), not for one or two items.

            When you talk about a specific film or show you genuinely know
            (never guess, never invent facts), PROACTIVELY offer one short fun
            fact or behind-the-scenes tidbit — don't wait to be asked. Wrap
            ANY words that reveal a plot point (a twist, an ending, a death,
            who did it) in double pipes: ||like this||. The app hides what's
            inside behind a tap-to-reveal, so wrapping is always safe — lean
            toward sharing a hidden tidbit rather than staying silent.
            For a sentence-long spoiler, put it on its OWN line with a blank line
            before AND after, so it renders as a clean blurred block:

              Loved the ending.

              ||Bruce Willis was dead the whole time.||

            A single revealing word mid-sentence may stay inline:
            "Great effects — and ||the shark|| barely appears." Don't pipe
            ordinary, non-spoiler trivia (release year, cast, budget).
            """,
            tool_calls: nil,
            tool_call_id: nil
        )

        var msgs: [ChatCompletionsRequest.Message] = [systemMessage]
        for msg in history.suffix(8) {
            switch msg.role {
            case .user:
                msgs.append(.init(role: "user", content: msg.content, tool_calls: nil, tool_call_id: nil))
            case .assistant:
                if let call = msg.toolCall {
                    let argsString = (try? String(
                        data: JSONEncoder().encode(call.arguments),
                        encoding: .utf8
                    )) ?? "{}"
                    let tcID = call.id ?? "call_\(abs(msg.id.uuidString.hashValue))"
                    msgs.append(.init(
                        role: "assistant",
                        content: msg.content.isEmpty ? nil : msg.content,
                        tool_calls: [.init(
                            id: tcID,
                            type: "function",
                            function: .init(name: call.name, arguments: argsString)
                        )],
                        tool_call_id: nil
                    ))
                } else {
                    msgs.append(.init(role: "assistant", content: msg.content, tool_calls: nil, tool_call_id: nil))
                }
            case .tool:
                let tcID = msg.toolCall?.id ?? "call_\(abs(msg.id.uuidString.hashValue))"
                msgs.append(.init(
                    role: "tool",
                    content: msg.toolResult ?? "",
                    tool_calls: nil,
                    tool_call_id: tcID
                ))
            }
        }
        msgs.append(.init(role: "user", content: prompt, tool_calls: nil, tool_call_id: nil))

        let apiTools = tools.map { t in
            ChatCompletionsRequest.Tool(
                type: "function",
                function: .init(name: t.name, description: t.description, parameters: t.inputSchema)
            )
        }
        return ChatCompletionsRequest(model: model, messages: msgs, tools: apiTools.isEmpty ? nil : apiTools, tool_choice: apiTools.isEmpty ? nil : "auto")
    }
}

public enum OpenAIError: Error, Equatable, Sendable, LocalizedError {
    case http(status: Int, body: String)
    case decoding(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            // Try to surface the OpenAI/OpenRouter-style {"error":{"message":"..."}}.
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String, !msg.isEmpty {
                return "HTTP \(status): \(msg)"
            }
            return "HTTP \(status) from AI provider."
        case .decoding(let msg):
            return "Couldn't decode AI response: \(msg)"
        case .empty:
            return "AI provider returned an empty response."
        }
    }
}

// MARK: - Wire types

public struct ChatCompletionsRequest: Encodable, Sendable {
    public let model: String
    public let messages: [Message]
    public let tools: [Tool]?
    public let tool_choice: String?

    public struct Message: Encodable, Sendable {
        public let role: String
        public let content: String?
        public let tool_calls: [ToolCallWire]?
        public let tool_call_id: String?
    }

    public struct ToolCallWire: Encodable, Sendable {
        public let id: String
        public let type: String
        public let function: Function
        public struct Function: Encodable, Sendable {
            public let name: String
            public let arguments: String
        }
    }

    public struct Tool: Encodable, Sendable {
        public let type: String
        public let function: Function
        public struct Function: Encodable, Sendable {
            public let name: String
            public let description: String
            public let parameters: JSONValue
        }
    }
}

public struct ChatCompletionsResponse: Decodable, Sendable {
    public let choices: [Choice]
    public struct Choice: Decodable, Sendable {
        public let message: Message
    }
    public struct Message: Decodable, Sendable {
        public let role: String
        public let content: String?
        public let tool_calls: [ToolCallWire]?
    }
    public struct ToolCallWire: Decodable, Sendable {
        public let id: String
        public let type: String
        public let function: Function
        public struct Function: Decodable, Sendable {
            public let name: String
            public let arguments: String
        }
    }
}
