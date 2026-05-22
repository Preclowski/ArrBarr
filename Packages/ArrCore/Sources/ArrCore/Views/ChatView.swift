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
        // iMessage-style: scrolling messages fill the surface, the input bar
        // floats over the bottom with a liquid-glass / material background.
        // ZStack — not `safeAreaInset` — because the inset modifier reacts
        // to any identity change in its parent view tree (e.g. messages's
        // empty-vs-populated branches re-render on every keystroke), which
        // re-mounted the TextField and lost focus mid-typing in `SearchView`.
        // The ZStack here keeps the bar as a stable sibling. The messages
        // ScrollView already pads its content for the bar's height (see
        // `messages` below) so nothing scrolls under it.
        ZStack(alignment: .bottom) {
            messages
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 8) {
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
                inputBar
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
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
                        // Bottom reservation so the floating input bar /
                        // confirm card don't cover the last message.
                        Color.clear.frame(height: 56)
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
            // Trash lives top-leading so it doesn't fight the user's own
            // trailing-aligned message bubble. Hover-revealed thinMaterial
            // pill, only when there's something to clear.
            .overlay(alignment: .topLeading) {
                if !viewModel.messages.isEmpty {
                    Button(action: { viewModel.clear() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("Clear chat", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Clear conversation", bundle: .module))
                    .disabled(viewModel.pendingConfirm != nil)
                    .opacity(clearHovered ? 1 : 0.0)
                    .padding(.top, 6)
                    .padding(.leading, 8)
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
                .foregroundStyle(.secondary)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassyFloatingBar()
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

}

private struct MessageBubble: View {
    let message: ChatMessage
    @State private var expanded = false
    @EnvironmentObject var configStore: ConfigStore

    /// iMessage-style routing: user prompts on the trailing edge in an accent
    /// bubble, assistant prose leading in a secondary bubble. LLM tool calls
    /// (plain + rich) span the full width — they're conceptually "system
    /// output", not either party's voice. There used to be `.userAdd` cases
    /// for tap-to-add status pills, but tap-to-add now opens a SearchAddPanel
    /// overlay instead of writing a status row, so those cases are gone.
    var body: some View {
        switch kind {
        case .user:
            row(trailing: true) { userBubble(message.content) }
        case .assistant:
            row(trailing: false) { assistantBubble(message.content) }
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

    /// Full-width section for an LLM-driven tool result that brought a rich
    /// payload (search results, library lists, calendar etc.). The header
    /// "Tool call: X" label sits above the carousel; tap on a card inside
    /// is wired by the carousel itself.
    @ViewBuilder
    private func carouselSection(headerKey: String) -> some View {
        if let rich = message.richContent {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    Text(verbatim: headerKey)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
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

    /// Display category derived from `ChatMessage`. Tool messages all come
    /// from the LLM now; tap-to-add takes a different (overlay-based) path
    /// that doesn't write to the chat.
    private enum Kind { case user, assistant, llmTool }

    private var kind: Kind {
        switch message.role {
        case .user:      return .user
        case .assistant: return .assistant
        case .tool:      return .llmTool
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
