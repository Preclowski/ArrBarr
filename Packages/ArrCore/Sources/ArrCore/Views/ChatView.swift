import SwiftUI

public struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject var configStore: ConfigStore
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool
    @AppStorage("ArrBarr.chatTipSeen") private var chatTipSeen: Bool = false

    // MARK: - Rotating placeholder
    /// Cycles through example prompts while the input is empty.
    /// Rotates every 4 seconds. Freezes if the user starts typing.
    @State private var placeholderIndex: Int = 0
    @State private var placeholderTimer: Timer?

    /// Example prompts shown in the rotating placeholder. First entry
    /// nudges toward the swipe-quiz feature explicitly; the rest mix
    /// general chat with more quiz examples so users learn there's a
    /// dedicated deck mode.
    private static let placeholderExamples: [LocalizedStringKey] = [
        "Try: give me a quiz of cozy 90s comedies",
        "Ask: what's good in my library?",
        "Try: pokaż mi quiz na sobotę wieczór",
        "Ask: more like Dune (2021)",
        "Try: surprise me with a quiz",
    ]

    private var currentPlaceholder: LocalizedStringKey {
        Self.placeholderExamples[placeholderIndex % Self.placeholderExamples.count]
    }

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
                firstLaunchTip
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
                        let latestDiscoverID = viewModel.latestDiscoverSessionMessageID
                        ForEach(viewModel.messages.filter { !Self.shouldHide($0) }) { msg in
                            MessageBubble(message: msg, latestDiscoverSessionMessageID: latestDiscoverID).id(msg.id)
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
                            Text("New chat", bundle: .module)
                                .scaledFont(size: 11, weight: .medium)
                        }
                        .foregroundStyle(clearHovered ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .glassyFloatingBar()
                    .help(Text("Start a new chat", bundle: .module))
                    .opacity(clearHovered ? 1 : 0.55)
                    .padding(.top, 8)
                    .padding(.leading, 10)
                    .animation(.easeOut(duration: 0.15), value: clearHovered)
                }
            }
            .onHover { clearHovered = $0 }
        }
    }

    /// Curated mix exercising each tool family the chat has:
    /// - taste-based suggestions (suggest_titles, both kinds)
    /// - person credits (tmdb_search_person → tmdb_person_*_credits)
    /// - calendar (whats-on-this-week)
    /// - discover-style filters (tmdb_discover_*)
    /// — so a fresh user sees the breadth, not just "find a movie".
    /// Locale-aware list of currently-visible *arr services. Empty
    /// state falls back to the canonical trio so the hint never reads
    /// as a placeholder.
    private var configuredArrsLabel: String {
        var names: [String] = []
        if configStore.sonarr.isVisible { names.append("Sonarr") }
        if configStore.radarr.isVisible { names.append("Radarr") }
        if configStore.lidarr.isVisible { names.append("Lidarr") }
        if configStore.whisparr.isVisible { names.append("Whisparr") }
        if names.isEmpty { names = ["Sonarr", "Radarr", "Lidarr"] }
        let formatter = ListFormatter()
        formatter.locale = configStore.currentLocale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }

    private static let suggestions: [String] = [
        "Suggest a series like Mr. Robot",
        "Films in the style of Wes Anderson",
        "Movies with Adam Sandler",
        "What's coming this week?",
        "Sci-fi films from the 90s",
        "Best comedies of the last 5 years",
    ]

    private var emptyHint: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .scaledFont(size: 28, weight: .light)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            // Dynamic hint: lists only the *arrs the user actually has
            // configured. Was a hardcoded "Sonarr, Radarr or Lidarr"
            // which was both untranslated and lying — if the user only
            // has Radarr configured, suggesting Sonarr was noise.
            // ListFormatter handles locale-aware joining (PL "Sonarra,
            // Radarra i Lidarra", EN "Sonarr, Radarr, and Lidarr").
            Text(String(format: String(localized: "Ask about %@", bundle: .module), configuredArrsLabel))
                .scaledFont(size: 12, weight: .regular)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        draft = ""
                        Task { await viewModel.send(suggestion) }
                    } label: {
                        Text(suggestion)
                            .scaledFont(size: 12)
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
            TextField(
                text: $draft,
                prompt: Text(currentPlaceholder, bundle: .module),
                axis: .vertical
            ) {
                EmptyView()
            }
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .onSubmit(send)
            .lineLimit(1...4)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .scaledFont(size: 22)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isThinking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassyFloatingBar()
        .onAppear { startPlaceholderTimer() }
        .onDisappear { placeholderTimer?.invalidate(); placeholderTimer = nil }
        .onChange(of: draft) { _, newValue in
            // Freeze rotation while the user is typing.
            if !newValue.isEmpty {
                placeholderTimer?.invalidate()
                placeholderTimer = nil
            } else if placeholderTimer == nil {
                startPlaceholderTimer()
            }
        }
    }

    private func startPlaceholderTimer() {
        placeholderTimer?.invalidate()
        placeholderTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            Task { @MainActor in
                withAnimation(.smooth(duration: 0.4)) {
                    placeholderIndex = (placeholderIndex + 1) % Self.placeholderExamples.count
                }
            }
        }
    }

    @ViewBuilder
    private var firstLaunchTip: some View {
        if !chatTipSeen {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.tint)
                Text("Tip: ask for a quiz of movies or shows to start swiping.", bundle: .module)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: { chatTipSeen = true }) {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 12)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    private func send() {
        let text = draft
        draft = ""
        chatTipSeen = true   // first interaction = tip's job is done
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
    var latestDiscoverSessionMessageID: UUID? = nil
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
        Text(Self.attributed(text))
            .scaledFont(size: 13)
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
                    blurWhisparr: configStore.blurWhisparrPosters,
                    isResumable: latestDiscoverSessionMessageID == message.id
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
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text(verbatim: label)
                    .scaledFont(size: 11, weight: .semibold)
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
    ///
    /// We trim trailing whitespace before parsing: `.inlineOnlyPreservingWhitespace`
    /// keeps any newlines or spaces the model tacked on at the end, and
    /// those render as a visible half-line of empty space inside the
    /// bubble. The trim is leaf-only so legitimate intra-message
    /// whitespace (mid-paragraph line breaks) stays put.
    static func attributed(_ raw: String) -> AttributedString {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: trimmed, options: opts) {
            return attr
        }
        return AttributedString(trimmed)
    }
}

private struct ThinkingRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Reserve the same 18pt column as MessageBubble's icon so
            // the shimmer label aligns with bubble text below it. The
            // little dot is the "thought bubble" anchor.
            Image(systemName: "sparkle")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
            ShimmerThinkingLabel()
            Spacer(minLength: 0)
        }
    }
}
