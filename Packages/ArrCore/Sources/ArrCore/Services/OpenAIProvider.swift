import Foundation

public struct OpenAIProvider: LLMProvider {
    private let config: OpenAIConfig
    private let session: URLSession

    public init(config: OpenAIConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public var isAvailable: Bool { config.isConfigured }

    public func respond(prompt: String, tools: [LLMTool], history: [ChatMessage]) async throws -> LLMResponse {
        let body = Self.buildRequestBody(
            model: config.model,
            prompt: prompt,
            tools: tools,
            history: history
        )
        let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("https://github.com/Preclowski/ArrBarr", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("ArrBarr", forHTTPHeaderField: "X-Title")
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

    static func buildRequestBody(model: String, prompt: String, tools: [LLMTool], history: [ChatMessage]) -> ChatCompletionsRequest {
        let systemMessage = ChatCompletionsRequest.Message(
            role: "system",
            content: """
            You are ArrBarr's in-app assistant for Sonarr (TV) and Radarr (movies).
            Reply in English, in a short, friendly tone. The user may be Polish — keep titles as the user wrote them.
            Call a tool when the request needs server data or an action. Otherwise just answer.
            Only use tools from the provided list.

            Format your replies as plain prose. Do NOT use:
              • markdown tables
              • emoji
              • heading syntax (no #, ##, ###)
              • bullet or numbered lists (no -, *, 1.)
            You may use ONLY inline emphasis: **bold**, *italic*, `code`,
            [link](url). Keep replies short — usually one short paragraph.
            When listing several items, write them out as a sentence with
            commas, or use em-dashes inline.
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
