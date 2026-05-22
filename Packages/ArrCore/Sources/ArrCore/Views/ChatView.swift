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
                    onConfirm: { args in Task { await viewModel.confirmPending(with: args) } },
                    onCancel: { Task { await viewModel.cancelPending() } }
                )
            }
            Divider()
            inputBar
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
                LazyVStack(alignment: .leading, spacing: 8) {
                    if viewModel.messages.isEmpty {
                        emptyHint
                    }
                    ForEach(viewModel.messages.filter { !Self.shouldHide($0) }) { msg in
                        MessageBubble(message: msg).id(msg.id)
                    }
                    if viewModel.isThinking {
                        ThinkingRow()
                    }
                }
                .padding(12)
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

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ask anything about your Sonarr / Radarr.", bundle: .module)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Text("Try: \"What's coming this week?\" · \"Add Severance\"", bundle: .module)
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
        .padding(.top, 24)
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                if message.role == .tool {
                    if let rich = message.richContent {
                        // Rich result: always-visible header chip + carousel
                        Text("Tool call: \(message.content)", bundle: .module)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        RichToolResultView(
                            content: rich,
                            sonarr: configStore.sonarr,
                            radarr: configStore.radarr
                        )
                        .padding(.top, 4)
                    } else {
                        // Plain result: chevron-collapsible (add confirmations, errors, etc.)
                        Button {
                            withAnimation(.smooth(duration: 0.18)) { expanded.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text("Tool call: \(message.content)", bundle: .module)
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
                } else {
                    Text(Self.attributed(message.content))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
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

    private var symbol: String {
        switch message.role {
        case .user: return "person.circle"
        case .assistant: return "sparkles"
        case .tool: return "wrench.and.screwdriver"
        }
    }
    private var tint: Color {
        switch message.role {
        case .user: return .secondary
        case .assistant: return .purple
        case .tool: return .blue
        }
    }
}

private struct ThinkingRow: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Thinking…", bundle: .module).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 26)
    }
}
