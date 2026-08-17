import SwiftUI

/// The Assistant pane's taste-profile block: the generated paragraph (always
/// visible — hidden inference is the one wrong version), the user's own note,
/// the use-in-chat switch, and the recent quiz signals with per-row undo.
///
/// Lives inside the existing Assistant Form on both platforms, so it inherits
/// the grouped styling for free.
public struct TasteProfileSection: View {

    @State private var profileTick = 0   // bumps to re-read the stores
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var userNote: String = TasteProfileStore.shared.userNote
    @State private var useInChat: Bool = TasteProfileStore.shared.useInChat

    public init() {}

    public var body: some View {
        profileSection
        signalsSection
    }

    // MARK: - Profile

    @ViewBuilder
    private var profileSection: some View {
        Section {
            // `id: profileTick` — the store is not observable; local state
            // drives refresh after regenerate/remove actions.
            Group {
                if let paragraph = TasteProfileStore.shared.paragraph {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(paragraph)
                            .scaledFont(size: 12)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let updated = TasteProfileStore.shared.updatedAt {
                            HStack(spacing: 4) {
                                Text("settings.taste.sources", bundle: .module)
                                Text(updated, style: .date)
                            }
                            .scaledFont(size: 10)
                            .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("settings.taste.empty", bundle: .module)
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                }
            }
            .id(profileTick)

            TextField(text: $userNote, prompt: Text("settings.taste.notePrompt", bundle: .module)) {
                Text("settings.taste.noteLabel", bundle: .module)
            }
            .onSubmit { TasteProfileStore.shared.setUserNote(userNote) }
            .onChange(of: userNote) { _, new in
                TasteProfileStore.shared.setUserNote(new)
            }

            Toggle(isOn: $useInChat) {
                Text("settings.taste.useInChat", bundle: .module)
            }
            .onChange(of: useInChat) { _, new in
                TasteProfileStore.shared.setUseInChat(new)
            }

            HStack {
                Button {
                    regenerate()
                } label: {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("settings.taste.regenerate", bundle: .module)
                    }
                }
                .disabled(isGenerating)
                if let generationError {
                    Text(generationError)
                        .scaledFont(size: 10)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("settings.taste.title", bundle: .module)
        } footer: {
            Text("settings.taste.privacy", bundle: .module)
        }
    }

    private func regenerate() {
        isGenerating = true
        generationError = nil
        let store = ConfigStore.shared
        let provider = ChatViewModelFactory.makeBareProvider(
            chatProvider: store.chatProvider,
            openai: store.openai,
            appLanguage: store.appLanguage
        )
        let language = ChatViewModelFactory.replyLanguageName(appLanguage: store.appLanguage)
        Task { @MainActor in
            do {
                try await TasteProfileGenerator.regenerate(provider: provider, languageName: language)
            } catch {
                generationError = error.localizedDescription
            }
            isGenerating = false
            profileTick += 1
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
                        profileTick += 1
                    } label: {
                        Text("settings.taste.resetSkips", bundle: .module)
                            + Text(verbatim: " (\(skips))")
                    }
                }
            }
        } header: {
            Text("settings.taste.signals.title", bundle: .module)
        }
        .id(profileTick)
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
                profileTick += 1
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
