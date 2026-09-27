import SwiftUI

struct ChatView: View {
    var viewModel: ChatViewModel
    @EnvironmentObject var configStore: ConfigStore
    @State private var draft: String = ""
    @State private var quizPosterURLs: [URL] = LibraryPosterSampler.cached ?? []
    @FocusState private var inputFocused: Bool

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        // ZStack, not `safeAreaInset`: the inset re-mounts the TextField on parent
        // identity changes and loses focus mid-typing.
        ZStack(alignment: .bottom) {
            messages
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The view-model also refuses new sends while a confirm is pending.
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
        // `arrbarr://` chat links open in-app; anything unrecognised goes to the system.
        .environment(\.openURL, OpenURLAction { url in
            guard let link = ChatLink(url: url) else {
                return url.scheme == ChatLink.scheme ? .discarded : .systemAction
            }
            ChatLinkRouter.open(link)
            return .handled
        })
    }

    @State private var clearHovered: Bool = false

    /// The input bar is a sibling, not a safe-area inset, so content keeps clear itself.
    /// The conversation reserves extra for a confirm card and autoscroll.
    private static let inputBarReservation: CGFloat = 84
    private static let emptyStateReservation: CGFloat = 64

    /// Two surfaces: `ViewThatFits` in the empty state needs a real proposed
    /// height, and a ScrollView proposes infinity.
    @ViewBuilder
    private var messages: some View {
        if viewModel.messages.isEmpty && !viewModel.isThinking {
            emptyState
        } else {
            conversation
        }
    }

    private var emptyState: some View {
        ChatEmptyStateView(
            quizPosterURLs: quizPosterURLs,
            // "In cinemas" / "Airing now" come from TMDB; without a key the
            // model could only answer from stale memory, so the deck isn't offered.
            quizVariants: QuizFeatureCard.Variant.allCases.filter {
                $0 != .rightNow || !configStore.tmdbApiKey.isEmpty
            },
            locale: configStore.currentLocale,
            onQuizStart: { kind, variant in
                // A single kind, so the model opens one deck rather than two. Resolved
                // in the in-app language, else the model answers in the pre-switch one.
                let prompt = AppLocalized.string(variant.promptKey(for: kind),
                                                 locale: configStore.currentLocale)
                DiscoverViewModel.shared.beginLoading()
                Task {
                    await viewModel.send(prompt)
                    DiscoverViewModel.shared.endLoading()
                }
            },
            onSuggestionTap: { prompt in
                draft = ""
                Task { await viewModel.send(prompt) }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Self.emptyStateReservation)
        .task {
            if quizPosterURLs.isEmpty {
                quizPosterURLs = await LibraryPosterSampler.sample(configStore: configStore)
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    // Computed over the whole history: which card wins depends on
                    // tool calls that hadn't happened when the earlier one arrived.
                    let adjusted = ChatPersonCardDedupe.adjustments(for: viewModel.messages)
                    // Handed to every bubble so a link the model invented never becomes clickable.
                    let knownLinks = ChatLinkVerification.knownKeys(in: viewModel.messages)
                    // Present-but-nil: the message's only content was a person card
                    // another call now owns, so it drops out entirely.
                    let visible = viewModel.messages.filter {
                        !Self.shouldHide($0) && adjusted[$0.id] != ChatRichContent??.some(nil)
                    }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visible) { msg in
                            MessageBubble(message: msg, richOverride: adjusted[msg.id] ?? nil).id(msg.id)
                        }
                        if viewModel.isThinking {
                            ThinkingRow()
                        }
                        Color.clear.frame(height: Self.inputBarReservation).id("chatBottom")
                    }
                    .environment(\.chatKnownLinkKeys, knownLinks)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    // Keeps the floating "New chat" pill off the first bubble at rest.
                    .padding(.top, 44)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("chatBottom", anchor: .bottom) }
            }
            .onChange(of: viewModel.isThinking) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("chatBottom", anchor: .bottom) }
            }
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
                // 14pt, like both filter bars, so the glass pills share a type size.
                .scaledFont(size: 14)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit(send)
                #if os(macOS)
                // `.onSubmit` fires for Return and Shift+Return alike, so intercept only
                // Shift+Return; plain Return falls through to `.onSubmit`.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    draft.append("\n")
                    return .handled
                }
                #endif
                .lineLimit(1...4)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .scaledFont(size: 21)
                    // Measured as one text line so the glyph doesn't set the bar's height;
                    // it still draws at full size.
                    .frame(height: 17)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isThinking)
            .accessibilityLabel(Text("chat.send.button", bundle: .module))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Fixed radius, not a capsule: the field grows to 4 lines and a capsule would
        // balloon. 18.5 = half the one-line height, so at rest it matches the filter bars.
        .glassyFloatingBar(focused: inputFocused, cornerRadius: 18.5, inverted: true)
        // Next main-actor turn: the field isn't in the responder chain during
        // `onAppear`, and an earlier assignment is dropped.
        .onAppear { Task { inputFocused = true } }
    }

    private func send() {
        // `.onSubmit` bypasses the Send button's `.disabled`.
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !viewModel.isThinking else { return }
        draft = ""
        Task { await viewModel.send(text) }
    }

    /// A tool-call-only assistant message has empty content; its result lives
    /// in the following .tool message.
    static func shouldHide(_ msg: ChatMessage) -> Bool {
        guard msg.role == .assistant else { return false }
        return msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}

private struct MessageBubble: View {
    let message: ChatMessage
    /// Replaces the message's payload when the de-duplicator stripped a person
    /// card another tool call in the same turn now owns.
    var richOverride: ChatRichContent?
    @State private var expanded = false
    @EnvironmentObject var configStore: ConfigStore

    private var rich: ChatRichContent? { richOverride ?? message.richContent }

    var body: some View {
        switch kind {
        case .user:
            row(trailing: true) { userBubble(message.content) }
        case .assistant:
            row(trailing: false) { assistantBubble(message.content) }
        case .llmTool:
            if rich != nil {
                row(trailing: false, fullWidth: true) {
                    carouselSection(headerKey: "Tool call: \(message.content)")
                }
            } else {
                row(trailing: false) { llmToolBubble }
            }
        }
    }

    @ViewBuilder
    private func row<Content: View>(trailing: Bool, fullWidth: Bool = false,
                                    @ViewBuilder _ content: () -> Content) -> some View {
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
            // Permanent gutter so the copy badge never lands on text or reflows it.
            .padding(.trailing, CopyBadge.gutter)
            .padding(.bottom, CopyBadge.floor)
            .overlay(alignment: .bottomTrailing) { CopyBadge(text: text, tint: .white) }
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
    }

    private func assistantBubble(_ text: String) -> some View {
        MarkdownMessage(text: text, baseSize: 13)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .padding(.trailing, CopyBadge.gutter)
            .padding(.bottom, CopyBadge.floor)
            // Copies the raw Markdown source, the fallback for tables and code that
            // render as separately-selectable views.
            .overlay(alignment: .bottomTrailing) { CopyBadge(text: text) }
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            // textSelection is owned by MarkdownMessage (it disables selection on
            // spoiler messages so the reveal tap works).
    }

    @ViewBuilder
    private var llmToolBubble: some View {
        // Chevron trails the label so toggling it doesn't shift the label.
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

    @ViewBuilder
    private func carouselSection(headerKey: String) -> some View {
        if let rich {
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

    private enum Kind { case user, assistant, llmTool }

    private var kind: Kind {
        switch message.role {
        case .user:      return .user
        case .assistant: return .assistant
        case .tool:      return .llmTool
        }
    }

    /// Trailing whitespace is trimmed first: `.inlineOnlyPreservingWhitespace`
    /// keeps it and it renders as an empty half-line in the bubble.
    static func attributed(_ raw: String) -> AttributedString {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

}

/// Always visible inside the bubble: a hover-only badge below it was unreachable,
/// since leaving the bubble to reach it hid it.
private struct CopyBadge: View {
    let text: String
    var tint: Color?
    @State private var hovering = false
    @State private var copied = false

    static let gutter: CGFloat = 18
    static let floor: CGFloat = 4

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .scaledFont(size: 9, weight: .medium)
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 18, height: 17)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(copied ? 1 : (hovering ? 0.95 : 0.35))
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: copied)
        .onHover { hovering = $0 }
        .help(Text("Copy message", bundle: .module))
        .accessibilityLabel(Text("Copy message", bundle: .module))
        .padding(.trailing, 3)
        .padding(.bottom, 2)
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

private struct ThinkingRow: View {
    // Cycled so a long tool round doesn't read as stuck.
    private static let phrases: [LocalizedStringKey] = ["Thinking…", "Working…", "Almost there…"]
    @State private var phase = 0

    var body: some View {
        // Matches MessageBubble's icon column (18pt + 8pt spacing).
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
