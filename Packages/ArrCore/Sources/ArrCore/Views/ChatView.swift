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

    @State private var clearHovered: Bool = false

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
            // Trash button used to live in a dedicated topBar with a Divider
            // — it dominated an otherwise minimal chat surface. Tuck it as a
            // hover-revealed overlay at top-trailing instead; only appears
            // when there's something to clear and the mouse is in the chat.
            .overlay(alignment: .topTrailing) {
                if !viewModel.messages.isEmpty {
                    Button(action: { viewModel.clear() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Clear conversation", bundle: .module))
                    .disabled(viewModel.pendingConfirm != nil)
                    .opacity(clearHovered ? 1 : 0.0)
                    .padding(.top, 6)
                    .padding(.trailing, 8)
                    .animation(.easeOut(duration: 0.15), value: clearHovered)
                }
            }
            .onHover { clearHovered = $0 }
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

    /// iMessage-style routing: user prompts and user-tap statuses align to the
    /// trailing edge in an accent bubble; assistant prose aligns leading in a
    /// secondary bubble. Tool plumbing (rich carousels, raw LLM tool calls)
    /// spans the full width — they don't fit a bubble and they're
    /// conceptually "system output", not either party's voice.
    var body: some View {
        switch kind {
        case .user:
            row(trailing: true) { userBubble(message.content) }
        case .assistant:
            row(trailing: false) { assistantBubble(message.content) }
        case .userAdd(let cancelled):
            row(trailing: true) { addStatusBubble(cancelled: cancelled) }
        case .userAddWithResults:
            row(trailing: false, fullWidth: true) { carouselSection(headerKey: nil) }
        case .llmTool:
            if message.richContent != nil {
                row(trailing: false, fullWidth: true) {
                    carouselSection(headerKey: "Tool call: \(message.content)")
                }
            } else {
                row(trailing: false) { llmToolBubble }
            }
        }
    }

    /// Wraps a bubble in the side-aligned row with the right `Spacer`. With
    /// `fullWidth`, the content takes the full chat column (carousels need it).
    @ViewBuilder
    private func row<Content: View>(trailing: Bool, fullWidth: Bool = false,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        // Bubble max-width 340 (out of ~376 usable column) — wide enough to
        // avoid skinny text columns on common chat phrases, narrow enough to
        // still read as a side-aligned bubble.
        HStack(spacing: 0) {
            if trailing && !fullWidth { Spacer(minLength: 16) }
            content()
                .frame(maxWidth: fullWidth ? .infinity : 340, alignment: trailing ? .trailing : .leading)
            if !trailing && !fullWidth { Spacer(minLength: 16) }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }

    // MARK: - Bubble flavours

    private func userBubble(_ text: String) -> some View {
        Text(Self.attributed(text))
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
    }

    private func assistantBubble(_ text: String) -> some View {
        Text(Self.attributed(text))
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Compact status pill for tap-to-add outcomes — same trailing column as
    /// the user prompt that triggered it, so success and cancel read as a
    /// continuation of the user's own action.
    private func addStatusBubble(cancelled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: cancelled ? "xmark.circle" : "plus.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(cancelled ? Color.secondary : Color.green)
            Text(message.content)
                .font(.system(size: 12))
                .foregroundStyle(cancelled ? .secondary : .primary)
                .strikethrough(cancelled, color: .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    @ViewBuilder
    private var llmToolBubble: some View {
        // Header layout intentionally mirrors `carouselSection`'s header so
        // a series of plain + rich tool calls in a row line up on the same
        // leading X. The chevron lives at the trailing end of the header
        // row, not before the label, so adding/removing it doesn't shift
        // the label horizontally.
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    Text(verbatim: "Tool call: \(message.content)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
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
                    .padding(.leading, 16)
                    .padding(.top, 2)
            }
        }
    }

    /// Full-width section for carousels (user-tap with results and LLM tool
    /// results with rich payloads). Optional header is the "Tool call: X"
    /// label that prepends LLM-driven carousels; user-tap pass nil.
    @ViewBuilder
    private func carouselSection(headerKey: String?) -> some View {
        if let rich = message.richContent {
            VStack(alignment: .leading, spacing: 4) {
                if let headerKey {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 10))
                            .foregroundStyle(.blue)
                        Text(verbatim: headerKey)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text(message.content)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                RichToolResultView(
                    content: rich,
                    sonarr: configStore.sonarr,
                    radarr: configStore.radarr,
                    lidarr: configStore.lidarr,
                    whisparr: configStore.whisparr,
                    blurWhisparr: configStore.blurWhisparrPosters
                )
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
