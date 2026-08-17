import SwiftUI

/// Settings → Quiz: the swipe feature's memory and its standing preferences.
///
/// Two sections, deliberately NOT a "taste profile": standing preferences are
/// the user's own written constraints (mood-independent by construction —
/// they wrote them as rules), and the signals list is the quiz's persistent
/// memory (skip cooldowns, vetoes, kept titles) with per-row removal.
///
/// The whole pane grays out while the assistant is off or unconfigured: the
/// note travels inside chat prompts and the signals only accumulate through
/// quiz decks, both of which need the assistant.
public struct QuizSettingsPane: View {

    @State private var signalsTick = 0   // bumps to re-read the store
    @State private var userNote: String = TasteProfileStore.shared.userNote
    @State private var useInChat: Bool = TasteProfileStore.shared.useInChat

    public init() {}

    /// Mirrors PopoverContentView.chatAvailable — the pane is about features
    /// that ride on the assistant, so it follows the same gate.
    private var assistantAvailable: Bool {
        let store = ConfigStore.shared
        guard store.aiEnabled else { return false }
        if DemoMode.isActive { return true }
        switch store.chatProvider {
        case .foundationModels:
            if #available(macOS 26.0, iOS 26.0, *) { return true }
            return false
        case .openai:
            return store.openai.isConfigured
        }
    }

    public var body: some View {
        Form {
            if !assistantAvailable {
                Section {
                    Label {
                        Text("settings.quiz.needsAssistant", bundle: .module)
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Group {
                standingSection
                signalsSection
            }
            .disabled(!assistantAvailable)
            .opacity(assistantAvailable ? 1 : 0.5)
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle(Text("settings.quiz.label", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Standing preferences

    @ViewBuilder
    private var standingSection: some View {
        Section {
            TextField(text: $userNote, prompt: Text("settings.taste.notePrompt", bundle: .module), axis: .vertical) {
                Text("settings.taste.noteLabel", bundle: .module)
            }
            .onChange(of: userNote) { _, new in
                TasteProfileStore.shared.setUserNote(new)
            }
            Toggle(isOn: $useInChat) {
                Text("settings.taste.useInChat", bundle: .module)
            }
            .onChange(of: useInChat) { _, new in
                TasteProfileStore.shared.setUseInChat(new)
            }
        } header: {
            Text("settings.quiz.standing.title", bundle: .module)
        } footer: {
            Text("settings.quiz.standing.footer", bundle: .module)
        }
    }

    // MARK: - Signals

    @ViewBuilder
    private var signalsSection: some View {
        Section {
            let all = SwipeSignalStore.shared.all
            let signals = Array(all.prefix(20))
            if signals.isEmpty {
                Text("settings.taste.signals.empty", bundle: .module)
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
            } else {
                // Totals up front — the list below caps at 20, and without
                // this line the cap reads as "that's all there is".
                summaryRow(all)
                ForEach(mediaGroups(signals), id: \.id) { group in
                    Text(group.label, bundle: .module)
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.top, 2)
                    ForEach(group.rows, id: \.key) { signal in
                        signalRow(signal)
                    }
                }
                let skips = all.filter { $0.kind == .skipped }.count
                if skips > 0 {
                    Button(role: .destructive) {
                        SwipeSignalStore.shared.resetSkips()
                        signalsTick += 1
                    } label: {
                        Text("settings.taste.resetSkips", bundle: .module)
                            + Text(verbatim: " (\(skips))")
                    }
                }
            }
        } header: {
            Text("settings.taste.signals.title", bundle: .module)
        }
        .id(signalsTick)
    }

    /// Rows split per media type — movies, series, music — matching how the
    /// arrs split the world. Entries persisted before the media field existed
    /// land in a trailing "Other" bucket rather than being guessed.
    private func mediaGroups(_ signals: [SwipeSignal])
        -> [(id: String, label: LocalizedStringKey, rows: [SwipeSignal])] {
        let buckets: [(String, LocalizedStringKey, (SwipeSignal) -> Bool)] = [
            ("movies", "settings.quiz.media.movies", { $0.media == .movie }),
            ("series", "settings.quiz.media.series", { $0.media == .show }),
            ("music", "settings.quiz.media.music", { $0.media == .music }),
            ("other", "settings.quiz.media.other", { $0.media == nil }),
        ]
        return buckets.compactMap { id, label, match in
            let rows = signals.filter(match)
            return rows.isEmpty ? nil : (id, label, rows)
        }
    }

    /// One capsule per kind with its total, in the same colours as the row
    /// badges — the vocabulary stays identical between summary and rows.
    private func summaryRow(_ all: [SwipeSignal]) -> some View {
        let kept = all.filter { $0.kind == .kept }.count
        let skipped = all.filter { $0.kind == .skipped }.count
        let veto = all.filter { $0.kind == .veto }.count
        return HStack(spacing: 6) {
            if kept > 0 { countBadge(count: kept, kind: .kept) }
            if skipped > 0 { countBadge(count: skipped, kind: .skipped) }
            if veto > 0 { countBadge(count: veto, kind: .veto) }
            Spacer()
        }
    }

    private func countBadge(count: Int, kind: SwipeSignal.Kind) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "\(count)")
                .scaledFont(size: 10, weight: .semibold)
            kindBadge(kind)
        }
    }

    private func signalRow(_ signal: SwipeSignal) -> some View {
        HStack(spacing: 8) {
            Text(signal.title)
                .scaledFont(size: 12)
                .lineLimit(1)
            Spacer()
            kindBadge(signal.kind)
            Button {
                SwipeSignalStore.shared.remove(key: signal.key)
                signalsTick += 1
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("settings.taste.removeSignal", bundle: .module))
            .help(Text("settings.taste.removeSignal", bundle: .module))
        }
    }

    private func kindBadge(_ kind: SwipeSignal.Kind) -> some View {
        let (key, color): (LocalizedStringKey, Color) = {
            switch kind {
            case .kept: return ("settings.taste.kind.kept", .green)
            case .skipped: return ("settings.taste.kind.skipped", .orange)
            case .veto: return ("settings.taste.kind.veto", .red)
            }
        }()
        return Text(key, bundle: .module)
            .scaledFont(size: 10, weight: .medium)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
