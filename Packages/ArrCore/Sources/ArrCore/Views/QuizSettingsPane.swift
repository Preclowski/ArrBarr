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
            let signals = Array(SwipeSignalStore.shared.all.prefix(20))
            if signals.isEmpty {
                Text("settings.taste.signals.empty", bundle: .module)
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(signals, id: \.key) { signal in
                    signalRow(signal)
                }
                let skips = SwipeSignalStore.shared.all.filter { $0.kind == .skipped }.count
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

    private func signalRow(_ signal: SwipeSignal) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(signal.title)
                    .scaledFont(size: 12)
                    .lineLimit(1)
                Text(signal.date, style: .date)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
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
