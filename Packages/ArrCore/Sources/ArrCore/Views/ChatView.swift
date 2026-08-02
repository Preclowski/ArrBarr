import SwiftUI

public struct ChatView: View {
    var viewModel: ChatViewModel
    @EnvironmentObject var configStore: ConfigStore
    @State private var draft: String = ""
    @State private var quizPosterURLs: [URL] = LibraryPosterSampler.cached ?? []
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
        // re-mounted the TextField and lost focus mid-typing on the search
        // surface — the same trap `QueueTabContent`'s filter bar sidesteps.
        // The ZStack here keeps the bar as a stable sibling. The messages
        // ScrollView already pads its content for the bar's height (see
        // `messages` below) so nothing scrolls under it.
        ZStack(alignment: .bottom) {
            messages
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Confirm card sits above the input bar when a destructive
            // tool is gated. Disables the input while pending (the
            // view-model also refuses new sends) so the user resolves
            // the gate before typing anything else.
            VStack(spacing: 8) {
                if let pending = viewModel.pendingConfirm {
                    ConfirmActionCard(
                        call: pending,
                        onConfirm: { viewModel.confirmPending() },
                        onCancel: { viewModel.cancelPending() }
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
                    ChatEmptyStateView(
                        quizPosterURLs: quizPosterURLs,
                        locale: configStore.currentLocale,
                        onQuizStart: { kind in
                            // Synthesised chat message that the LLM routes
                            // through `discover_in_quiz`. We name a SINGLE
                            // kind so the model opens one deck (it used to
                            // fire a movie session *and* a series session
                            // when the prompt said "movies and shows") and
                            // ask for a dozen-plus so the deck isn't thin.
                            let promptKey = kind == .movies
                                ? "chat.quizPrompt.movies"
                                : "chat.quizPrompt.series"
                            // Resolve in the *in-app* language, not the process
                            // language — otherwise the sent message stays in the
                            // pre-switch language and the model answers the whole
                            // turn in it (see AppLocalized).
                            let prompt = AppLocalized.string(promptKey, locale: configStore.currentLocale)
                            Task { await viewModel.send(prompt) }
                        },
                        onSuggestionTap: { prompt in
                            draft = ""
                            Task { await viewModel.send(prompt) }
                        }
                    )
                    .frame(maxWidth: .infinity, minHeight: 380)
                    // Sample a few library posters for the Quiz deck on first
                    // appearance; cached process-wide so re-entry is instant.
                    .task {
                        if quizPosterURLs.isEmpty {
                            quizPosterURLs = await LibraryPosterSampler.sample(configStore: configStore)
                        }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.messages.filter { !Self.shouldHide($0) }) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                        if viewModel.isThinking {
                            ThinkingRow()
                        }
                        // Bottom reservation so the floating input bar /
                        // confirm card don't cover the last message after
                        // autoscroll. Sized to clear the glass input bar +
                        // its bottom padding (56 was too short — the newest
                        // bubble landed behind the bar).
                        Color.clear.frame(height: 84).id("chatBottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    // Extra top inset so the floating "New chat" pill doesn't
                    // sit on the first bubble at rest (it may still overlap
                    // mid-scroll, which is fine).
                    .padding(.top, 44)
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("chatBottom", anchor: .bottom) }
            }
            // Also follow the thinking indicator + the growing last reply.
            .onChange(of: viewModel.isThinking) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("chatBottom", anchor: .bottom) }
            }
            // "New chat" sits top-leading so it doesn't fight the user's
            // trailing-aligned message bubble. Floating glass pill matching
            // the rest of the app's chrome language (tab bar, back button).
            // The trash icon used to live here but it read as destructive /
            // intrusive and felt unApple-y for "wipe the conversation".
            // `arrow.counterclockwise` + "New chat" carries the same intent
            // with iOS Messages / ChatGPT cadence — start over, not delete.
            // Visible at low opacity at rest so it's discoverable; lifts to
            // full on hover.
            .overlay(alignment: .topLeading) {
                if !viewModel.messages.isEmpty {
                    Button(action: { viewModel.clear() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .scaledFont(size: 11, weight: .medium)
                            Text("chat.newChat.button", bundle: .module)
                                .scaledFont(size: 11, weight: .medium)
                        }
                        .foregroundStyle(clearHovered ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .glassyFloatingBar()
                    .help(Text("chat.startANewChat.button", bundle: .module))
                    .opacity(clearHovered ? 1 : 0.55)
                    .padding(.top, 8)
                    .padding(.leading, 10)
                    .animation(.easeOut(duration: 0.15), value: clearHovered)
                }
            }
            .onHover { clearHovered = $0 }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {

            TextField(text: $draft, prompt: Text("chat.askAnything.button", bundle: .module), axis: .vertical) {
                Text("chat.askAnything.button", bundle: .module)
            }
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit(send)
                #if os(macOS)
                // Return sends (via `.onSubmit`); Shift+Return inserts a newline.
                // `.onSubmit` fires for BOTH and can't tell them apart, so
                // intercept only Shift+Return: append a newline and mark the
                // event handled so the submit doesn't also run. Plain Return
                // falls through (`.ignored`) to `.onSubmit` — keeping the proven
                // send path intact even if `onKeyPress` ever misses.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    draft.append("\n")
                    return .handled
                }
                #endif
                .lineLimit(1...4)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .scaledFont(size: 22)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isThinking)
            .accessibilityLabel(Text("chat.send.button", bundle: .module))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassyFloatingBar(focused: inputFocused)
        // Typeable the moment Chat is on screen, whether the panel just opened
        // on this tab or the user switched to it. Hopped to the next main-actor
        // turn because the field is not in the responder chain during
        // `onAppear`, and an assignment made before it is there is dropped.
        .onAppear { Task { @MainActor in inputFocused = true } }
    }

    private func send() {
        // Guard here too — the Send button is `.disabled` while thinking, but
        // the TextField's `.onSubmit` (Return key) bypasses that, so without
        // this a second prompt could fire mid-response.
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !viewModel.isThinking else { return }
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
            .scaledFont(size: 13)
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
    }

    private func assistantBubble(_ text: String) -> some View {
        // Full Markdown via swift-markdown (bold/italic/code, lists, headings,
        // block quotes and GFM tables). One path for every assistant message —
        // the old `||spoiler||` blur is gone (its markers are stripped inside
        // MarkdownMessage) so it can never bypass Markdown rendering.
        MarkdownMessage(text: text, baseSize: 13)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            // textSelection is owned by MarkdownMessage (it disables selection on
            // spoiler messages so the reveal tap works).
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
                        .scaledFont(size: 10)
                        .foregroundStyle(.blue)
                    Text(verbatim: "Tool call: \(message.content)")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 9, weight: .semibold)
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
                        .scaledFont(size: 10)
                        .foregroundStyle(.blue)
                    Text(verbatim: headerKey)
                        .scaledFont(size: 11, weight: .semibold)
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
    ///
    /// We trim trailing whitespace before parsing: `.inlineOnlyPreservingWhitespace`
    /// keeps any newlines or spaces the model tacked on at the end, and
    /// those render as a visible half-line of empty space inside the
    /// bubble. The trim is leaf-only so legitimate intra-message
    /// whitespace (mid-paragraph line breaks) stays put.
    static func attributed(_ raw: String) -> AttributedString {
        inlineMarkdown(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Inline-markdown parse without edge-trimming — used per spoiler segment
    /// so the whitespace adjoining `||markers||` survives reassembly.
    static func inlineMarkdown(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: s, options: opts) {
            return attr
        }
        return AttributedString(s)
    }

}

private struct ThinkingRow: View {
    // Cycle a few verbs so a long tool round doesn't read as "stuck on
    // Thinking…". Crossfades every ~1.8s.
    private static let phrases: [LocalizedStringKey] = ["Thinking…", "Working…", "Almost there…"]
    @State private var phase = 0

    var body: some View {
        // Match MessageBubble's icon-column layout (18pt frame + 8pt spacing)
        // so the spinner sits exactly where a message's sparkles/wrench icon
        // would, and the label aligns with bubble text.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, alignment: .center)
            Text(Self.phrases[phase], bundle: .module)
                .scaledFont(size: 13)
                .foregroundStyle(.secondary)
                .id(phase)
                .transition(.opacity)
            Spacer(minLength: 0)
        }
        .task {
            // Hold on the first phrase, then advance only while still shown.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.35)) {
                    phase = (phase + 1) % Self.phrases.count
                }
            }
        }
    }
}
