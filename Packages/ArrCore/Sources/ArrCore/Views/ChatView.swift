import SwiftUI

public struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject var configStore: ConfigStore
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !viewModel.messages.isEmpty {
                topBar
                Divider()
            }
            messages
            if let confirm = viewModel.pendingConfirm {
                ConfirmAddCard(
                    call: confirm,
                    sonarr: configStore.sonarr,
                    radarr: configStore.radarr,
                    lidarr: configStore.lidarr,
                    onConfirm: { args in Task { await viewModel.confirmPending(with: args) } },
                    onCancel: { Task { await viewModel.cancelPending() } }
                )
            }
            Divider()
            inputBar
        }
        .onReceive(NotificationCenter.default.publisher(for: .arrBarrChatRequestAdd)) { note in
            guard
                let toolName = note.userInfo?["toolName"] as? String,
                let draftArgs = note.userInfo?["draftArgs"] as? JSONValue,
                let intent = note.userInfo?["userIntent"] as? String
            else { return }
            Task { await viewModel.requestAdd(toolName: toolName, draftArgs: draftArgs, userIntent: intent) }
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Spacer()
            Button(action: { viewModel.clear() }) {
                Label("Clear", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Clear conversation", bundle: .module))
            .disabled(viewModel.pendingConfirm != nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.messages.isEmpty && !viewModel.isThinking {
                    emptyHint
                        .frame(maxWidth: .infinity, minHeight: 380)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.messages.filter { !Self.shouldHide($0) }) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                        if viewModel.isThinking {
                            ThinkingRow()
                        }
                    }
                    .padding(12)
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private static let suggestions: [String] = [
        "Movies with Adam Sandler",
        "Suggest a horror for tonight",
        "Sci-fi films from the 90s",
        "What's coming this week?",
        "Do I have The Bear?",
        "Best comedies of the last 5 years",
    ]

    private var emptyHint: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.purple)
            Text("Ask about Sonarr, Radarr or Lidarr", bundle: .module)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        draft = ""
                        Task { await viewModel.send(suggestion) }
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask anything…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit(send)
                .lineLimit(1...4)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isThinking)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await viewModel.send(text) }
    }

    /// Filter out content-less assistant messages — when the model only emits
    /// a tool call (no prose), we get an assistant ChatMessage with empty
    /// content and the tool result lives in the separate .tool message that
    /// follows. The bare icon for the empty assistant message is just noise.
    static func shouldHide(_ msg: ChatMessage) -> Bool {
        guard msg.role == .assistant else { return false }
        return msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func summarize(_ value: JSONValue) -> String {
        if case .object(let dict) = value {
            return dict.map { "\($0.key): \(stringify($0.value))" }.joined(separator: ", ")
        }
        return stringify(value)
    }
    static func stringify(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return String(b)
        case .number(let n): return String(n)
        case .string(let s): return s
        case .array(let a): return "[\(a.map(stringify).joined(separator: ", "))]"
        case .object(let o): return "{\(o.map { "\($0.key):\(stringify($0.value))" }.joined(separator: ","))}"
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    @State private var expanded = false
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        // Uniform layout for every chat row: icon column + content + optional
        // expandable details. The kind enum decides which icon, label format,
        // and whether the chevron is available.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kind.symbol)
                .font(.system(size: 12))
                .foregroundStyle(kind.tint)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                content
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .user, .assistant:
            Text(Self.attributed(message.content))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .userAdd(let cancelled):
            // Tap-to-add status line. Cancel state strikes through the title
            // and dims to secondary — same icon family, just a different
            // glyph, so success vs cancel reads at a glance.
            Text(message.content)
                .font(.system(size: 12))
                .foregroundStyle(cancelled ? .secondary : .primary)
                .strikethrough(cancelled, color: .secondary)

        case .llmTool:
            // LLM-issued tool result with rich payload: header label +
            // carousel. With plain text: chevron-collapsible — useful to
            // inspect raw tool output without dominating the chat.
            if let rich = message.richContent {
                Text("Tool call: \(message.content)", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                RichToolResultView(
                    content: rich,
                    sonarr: configStore.sonarr,
                    radarr: configStore.radarr,
                    lidarr: configStore.lidarr,
                    whisparr: configStore.whisparr,
                    blurWhisparr: configStore.blurWhisparrPosters
                )
                .padding(.top, 4)
            } else {
                chevronExpandable(label: "Tool call: \(message.content)")
            }

        case .userAddWithResults:
            // Tap-to-add that the backend turned into a result list (rare —
            // e.g. add-by-title returned multiple candidates). Render same
            // header as a user-tap status, then the carousel.
            if let rich = message.richContent {
                Text(message.content)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                RichToolResultView(
                    content: rich,
                    sonarr: configStore.sonarr,
                    radarr: configStore.radarr,
                    lidarr: configStore.lidarr,
                    whisparr: configStore.whisparr,
                    blurWhisparr: configStore.blurWhisparrPosters
                )
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func chevronExpandable(label: String) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if expanded, let result = message.toolResult, !result.isEmpty {
            Text(result)
                .font(.system(size: 11).monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 13)
                .padding(.top, 2)
        }
    }

    /// Display category derived from `ChatMessage`. The role alone doesn't
    /// capture the user-tap vs LLM distinction for tool messages — we use
    /// the convention that `requestAdd` stores `userIntent` in `content`
    /// while the LLM path stores the raw tool name, and the toolResult's
    /// "(cancelled by user)" marker flags the cancel branch.
    private enum Kind {
        case user, assistant
        case userAdd(cancelled: Bool)
        case userAddWithResults
        case llmTool

        var symbol: String {
            switch self {
            case .user: return "person.circle"
            case .assistant: return "sparkles"
            case .userAdd(let cancelled): return cancelled ? "xmark.circle" : "plus.circle.fill"
            case .userAddWithResults: return "plus.circle.fill"
            case .llmTool: return "wrench.and.screwdriver"
            }
        }

        var tint: Color {
            switch self {
            case .user: return .secondary
            case .assistant: return .purple
            case .userAdd(let cancelled): return cancelled ? .secondary : .green
            case .userAddWithResults: return .green
            case .llmTool: return .blue
            }
        }
    }

    private var kind: Kind {
        switch message.role {
        case .user:      return .user
        case .assistant: return .assistant
        case .tool:
            // user-tap path stores friendly intent in content; LLM path
            // stores the raw tool name there.
            let isUserInitiated = message.content != (message.toolCall?.name ?? "")
            if !isUserInitiated { return .llmTool }
            if message.richContent != nil { return .userAddWithResults }
            let cancelled = (message.toolResult ?? "").contains("cancelled")
            return .userAdd(cancelled: cancelled)
        }
    }

    /// Parse inline markdown (bold, italic, code, links). Block-level markdown
    /// like headings or lists falls back to inline rendering — the model
    /// usually emits paragraph + inline emphasis which renders cleanly.
    static func attributed(_ raw: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: raw, options: opts) {
            return attr
        }
        return AttributedString(raw)
    }
}

private struct ThinkingRow: View {
    var body: some View {
        // Match MessageBubble's icon-column layout (18pt frame + 8pt spacing)
        // so the spinner sits exactly where a message's sparkles/wrench icon
        // would, and the "Thinking…" label aligns with bubble text.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, alignment: .center)
            Text("Thinking…", bundle: .module)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
