import SwiftUI

public struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            messages
            if let confirm = viewModel.pendingConfirm {
                confirmBanner(for: confirm)
            }
            Divider()
            inputBar
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if viewModel.messages.isEmpty {
                        emptyHint
                    }
                    ForEach(viewModel.messages) { msg in
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
            Text("Ask anything about your Sonarr / Radarr.")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Text("Try: \"What's coming this week?\" · \"Add Severance\"")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
        .padding(.top, 24)
    }

    private func confirmBanner(for call: ToolCall) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Confirm: \(call.name)")
                    .font(.system(size: 12, weight: .semibold))
                Text(Self.summarize(call.arguments))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { Task { await viewModel.cancelPending() } }
                .controlSize(.small)
            Button("Confirm") { Task { await viewModel.confirmPending() } }
                .controlSize(.small)
#if os(macOS)
                .keyboardShortcut(.defaultAction)
#endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
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
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                if message.role == .tool {
                    Text(message.content)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let result = message.toolResult {
                        Text(result)
                            .font(.system(size: 12).monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(message.content)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
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
            Text("Thinking…").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 26)
    }
}
