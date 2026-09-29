import Foundation
import OSLog
import MediaKit

nonisolated struct OpenAIProvider: LLMProvider {
    private let config: OpenAIConfig
    private let session: URLSession
    private let replyLanguage: String
    private static let log = Logger(category: "Chat")

    init(config: OpenAIConfig, session: URLSession = .shared, replyLanguage: String = "English") {
        self.config = config
        self.session = session
        self.replyLanguage = replyLanguage
    }

    var isAvailable: Bool { config.isConfigured }

    /// `GET {baseURL}/models` with the Bearer key.
    func testConnection() async throws {
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

    func respond(prompt: String, tools: [ToolDefinition], history: [ChatMessage]) async throws -> LLMResponse {
        var body = Self.buildRequestBody(
            model: config.model,
            prompt: prompt,
            tools: tools,
            history: history,
            replyLanguage: replyLanguage,
            // Read per request so a regenerated or disabled profile applies on the next turn. Tool-less calls
            // (taste-profile generation itself) must not see the previous profile.
            tasteProfile: tools.isEmpty ? nil : TasteProfileStore.shared.promptBlock()
        )
        body.stream = true
        // Hidden reasoning is the quiz's whole wait (77 s measured on a flash model). Each host has its own
        // switch; an unknown host gets none rather than a field it may reject.
        let host = URL(string: config.baseURL)?.host?.lowercased() ?? ""
        if host.hasSuffix("deepseek.com") {
            body.thinking = .init(type: "disabled")
        } else if host.hasSuffix("openrouter.ai") {
            body.reasoning = .init(enabled: false)
        }
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw OpenAIError.empty
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("https://github.com/Preclowski/ArrBarr", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("ArrBarr", forHTTPHeaderField: "X-Title")
        // Reasoning models and multi-round tool loops outrun URLSession's 60 s default.
        req.timeoutInterval = 120
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        req.httpBody = try encoder.encode(body)

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.empty }

        // SSE `data:` lines feed the accumulator; anything else is the plain JSON body (errors, non-streaming hosts).
        var stream = ChatCompletionStream()
        var plainBody = ""
        var loggedReasoning = false
        var loggedAnswer = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else {
                plainBody += line + "\n"
                continue
            }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]" else { continue }
            let data = Data(payload.utf8)
            // Hosts that fail after the 200 (OpenRouter's upstream errors) send the error as a data line.
            if let failure = try? JSONDecoder().decode(StreamError.self, from: data) {
                throw OpenAIError.provider(failure.error.message)
            }
            guard let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data) else { continue }
            let delta = chunk.choices.first?.delta
            if !loggedReasoning, delta?.reasoning_content?.isEmpty == false || delta?.reasoning?.isEmpty == false {
                loggedReasoning = true
                Self.log.notice("stream: model is reasoning")
            }
            if !loggedAnswer, delta?.content?.isEmpty == false || delta?.tool_calls?.isEmpty == false {
                loggedAnswer = true
                Self.log.notice("stream: first answer bytes")
            }
            for touched in stream.apply(chunk) {
                ToolCallStreamContext.observer?(touched.name, touched.arguments)
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIError.http(status: http.statusCode, body: plainBody)
        }
        if stream.sawChunk {
            if stream.truncated {
                Self.log.notice("stream: reply cut off at the token limit")
                if stream.text.isEmpty && stream.toolCalls.isEmpty { throw OpenAIError.truncated }
            }
            return LLMResponse(text: stream.text, toolCalls: stream.toolCalls.map {
                ToolCall(id: $0.id, name: $0.name, arguments: .toolArguments($0.arguments))
            }, toolResults: nil)
        }
        let decoded: ChatCompletionsResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: Data(plainBody.utf8))
        } catch {
            throw OpenAIError.decoding(String(describing: error))
        }
        guard let choice = decoded.choices.first else { throw OpenAIError.empty }
        let toolCalls = (choice.message.tool_calls ?? []).map { call in
            ToolCall(id: call.id, name: call.function.name, arguments: .toolArguments(call.function.arguments))
        }
        return LLMResponse(text: choice.message.content ?? "", toolCalls: toolCalls, toolResults: nil)
    }

    // MARK: - History window

    /// Not `suffix(n)`: tool rounds would evict the user's question and the model keeps digging. The
    /// current turn is kept whole (over budget, its middle is dropped); earlier context fills the rest.
    static func window(_ history: [ChatMessage], budget: Int = 16) -> [ChatMessage] {
        guard history.count > budget else { return history }
        let turnStart = history.lastIndex { $0.role == .user } ?? history.startIndex
        let turn = Array(history[turnStart...])

        guard turn.count <= budget else {
            return [turn[0]] + turn.suffix(budget - 1)
        }
        let earlier = history[..<turnStart].suffix(budget - turn.count)
        return Array(earlier) + turn
    }

    // MARK: - Request building (pure — tested independently)

    static func buildRequestBody(model: String, prompt: String, tools: [ToolDefinition], history: [ChatMessage], replyLanguage: String = "English", tasteProfile: String? = nil) -> ChatCompletionsRequest {
        let arrs = SystemPromptComposer.arrsClause(tools: tools)
        let tasteClause = tasteProfile.map { "\n\($0)\n" } ?? ""
        let libraryClause = tools.isEmpty ? "" : (LibraryStats.shared.promptBlock().map { "\n\($0)\n" } ?? "")
        let systemMessage = ChatCompletionsRequest.Message(
            role: "system",
            content: """
            You are ArrBarr's in-app assistant for \(arrs) — and a film, TV and music obsessive at heart.
            \(SystemPromptComposer.persona)
            Always reply in the same language as the user's latest message — this takes priority. Only when their language is genuinely unclear, default to \(replyLanguage). Keep media titles exactly as the user wrote them.
            Call a tool when the request needs server data or an action. Otherwise just answer.
            Only use tools from the provided list.
            Division of labour: the taste is yours, the facts are the tools'. You decide WHAT to recommend; only the tools know what the user already owns (the arrs) and what they have already watched (the media server). So whenever you have named titles and the answer depends on their shelf — "something I don't have yet", "have I seen these", "what should I watch tonight" — call check_titles ONCE with the whole candidate list before you recommend, rather than guessing or firing a tool per title. A large library already owns the obvious classics: reach past the canon.
            Independent calls go out together, in the same turn. Browsing the shelf by filter and checking your own candidates answer different questions and neither needs the other's result — issuing them one after another costs the user an extra round for nothing.
            \(libraryClause)\(tasteClause)
            \(SystemPromptComposer.formattingClause)

            \(SystemPromptComposer.linkingClause)

            \(SystemPromptComposer.triviaClause)
            """,
            tool_calls: nil,
            tool_call_id: nil
        )

        var msgs: [ChatCompletionsRequest.Message] = [systemMessage]
        let history = Self.window(history)
        // OpenAI rejects a `tool` message whose `tool_calls` fell outside the window, so track the ids emitted here.
        var emittedToolCallIDs = Set<String>()
        for msg in history {
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
                    emittedToolCallIDs.insert(tcID)
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
                guard emittedToolCallIDs.contains(tcID) else { continue }
                msgs.append(.init(
                    role: "tool",
                    content: msg.toolResult ?? "",
                    tool_calls: nil,
                    tool_call_id: tcID
                ))
            }
        }
        // Empty prompt = continue from tool results already in history; a `user` copy of them reads as
        // a fresh instruction and sends the model off calling more tools.
        if !prompt.isEmpty {
            msgs.append(.init(role: "user", content: prompt, tool_calls: nil, tool_call_id: nil))
        }

        let apiTools = tools.map { t in
            ChatCompletionsRequest.Tool(
                type: "function",
                function: .init(name: t.name, description: t.description, parameters: t.inputSchema)
            )
        }
        return ChatCompletionsRequest(model: model, messages: msgs, tools: apiTools.isEmpty ? nil : apiTools, tool_choice: apiTools.isEmpty ? nil : "auto")
    }
}

enum OpenAIError: Error, Equatable, Sendable, LocalizedError {
    case http(status: Int, body: String)
    case decoding(String)
    case provider(String)
    case truncated
    case empty

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String, !msg.isEmpty {
                return "HTTP \(status): \(msg)"
            }
            return "HTTP \(status) from AI provider."
        case .decoding(let msg):
            return "Couldn't decode AI response: \(msg)"
        case .provider(let msg):
            return "AI provider error: \(msg)"
        case .truncated:
            return "AI provider stopped at its token limit before answering."
        case .empty:
            return "AI provider returned an empty response."
        }
    }
}

// MARK: - Wire types

nonisolated struct ChatCompletionsRequest: Encodable, Sendable {
    let model: String
    let messages: [Message]
    let tools: [Tool]?
    let tool_choice: String?
    var stream: Bool? = nil
    var thinking: Thinking? = nil
    var reasoning: Reasoning? = nil

    struct Thinking: Encodable, Sendable { let type: String }
    struct Reasoning: Encodable, Sendable { let enabled: Bool }

    struct Message: Encodable, Sendable {
        let role: String
        let content: String?
        let tool_calls: [ToolCallWire]?
        let tool_call_id: String?
    }

    struct ToolCallWire: Encodable, Sendable {
        let id: String
        let type: String
        let function: Function
        struct Function: Encodable, Sendable {
            let name: String
            let arguments: String
        }
    }

    struct Tool: Encodable, Sendable {
        let type: String
        let function: Function
        struct Function: Encodable, Sendable {
            let name: String
            let description: String
            let parameters: JSONValue
        }
    }
}

nonisolated struct ChatCompletionsResponse: Decodable, Sendable {
    let choices: [Choice]
    struct Choice: Decodable, Sendable {
        let message: Message
    }
    struct Message: Decodable, Sendable {
        let role: String
        let content: String?
        let tool_calls: [ToolCallWire]?
    }
    struct ToolCallWire: Decodable, Sendable {
        let id: String
        let type: String
        let function: Function
        struct Function: Decodable, Sendable {
            let name: String
            let arguments: String
        }
    }
}

nonisolated struct StreamError: Decodable, Sendable {
    let error: Body
    struct Body: Decodable, Sendable { let message: String }
}

enum ToolCallStreamContext {
    @TaskLocal nonisolated static var observer: (@Sendable (_ name: String, _ arguments: String) -> Void)?
}

nonisolated struct ChatCompletionChunk: Decodable, Sendable {
    let choices: [Choice]
    struct Choice: Decodable, Sendable {
        let delta: Delta?
        let finish_reason: String?
    }
    struct Delta: Decodable, Sendable {
        let content: String?
        let reasoning_content: String?
        let reasoning: String?
        let tool_calls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey { case content, reasoning_content, reasoning, tool_calls }

        // Reasoning fields vary by host (string here, object there); a shape
        // we don't know must not cost us the chunk.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            content = try c.decodeIfPresent(String.self, forKey: .content)
            reasoning_content = try? c.decodeIfPresent(String.self, forKey: .reasoning_content)
            reasoning = try? c.decodeIfPresent(String.self, forKey: .reasoning)
            tool_calls = try c.decodeIfPresent([ToolCallDelta].self, forKey: .tool_calls)
        }
    }
    struct ToolCallDelta: Decodable, Sendable {
        let index: Int?
        let id: String?
        let function: Function?
        struct Function: Decodable, Sendable {
            let name: String?
            let arguments: String?
        }
    }
}

nonisolated struct ChatCompletionStream {
    struct PendingCall {
        var id: String?
        var name = ""
        var arguments = ""
    }

    private(set) var sawChunk = false
    private(set) var text = ""
    private(set) var truncated = false
    private var calls: [Int: PendingCall] = [:]

    var toolCalls: [PendingCall] {
        calls.keys.sorted().compactMap { calls[$0] }.filter { !$0.name.isEmpty }
    }

    mutating func apply(_ chunk: ChatCompletionChunk) -> [PendingCall] {
        sawChunk = true
        var touched: [PendingCall] = []
        for choice in chunk.choices {
            if choice.finish_reason == "length" { truncated = true }
            guard let delta = choice.delta else { continue }
            if let content = delta.content { text += content }
            for part in delta.tool_calls ?? [] {
                let index = part.index ?? 0
                var call = calls[index] ?? PendingCall()
                if let id = part.id, !id.isEmpty { call.id = id }
                if let name = part.function?.name, !name.isEmpty { call.name = name }
                if let fragment = part.function?.arguments, !fragment.isEmpty {
                    call.arguments += fragment
                    if !call.name.isEmpty { touched.append(call) }
                }
                calls[index] = call
            }
        }
        return touched
    }
}
