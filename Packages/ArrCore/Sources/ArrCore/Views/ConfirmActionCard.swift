import SwiftUI

/// In-chat gate for a destructive tool call: a plain-language description instead of raw JSON args.
/// Cancel returns "(cancelled by user)" so the model can adjust its plan.
struct ConfirmActionCard: View {
    let call: ToolCall
    let onConfirm: () -> Void
    let onCancel: () -> Void

    init(call: ToolCall, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.call = call
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        InlineConfirmCard(
            message: humanDescription,
            confirmLabelKey: "Confirm",
            onConfirm: onConfirm,
            onCancel: onCancel
        )
    }

    private var humanDescription: String {
        switch call.name {
        case "sonarr_monitor_season":
            let seasons = seasonNumbers()
            let joined = ListFormatter.localizedString(byJoining: seasons.map { String($0) })
            let state = boolArg("state") ?? true
            if state {
                return String(format: String(localized: "common.monitorSeasonSAnd.tooltip", bundle: .module), joined)
            } else {
                return String(format: String(localized: "common.stopMonitoringSeasonS.tooltip", bundle: .module), joined)
            }
        case "sonarr_search_episodes":
            let count = arrayArgCount("episodeIds")
            return String(format: String(localized: "common.searchLldEpisodeS.tooltip", bundle: .module), count)
        case "radarr_search_movie":
            return String(localized: "common.searchForThisMovie.tooltip", bundle: .module)
        case "lidarr_monitor_album":
            let state = boolArg("state") ?? true
            if state {
                return String(localized: "common.monitorThisAlbumAnd.tooltip", bundle: .module)
            } else {
                return String(localized: "common.stopMonitoringThisAlbum.tooltip", bundle: .module)
            }
        case "lidarr_search_album":
            return String(localized: "common.searchForThisAlbum.tooltip", bundle: .module)
        default:
            return String(format: String(localized: "common.run.tooltip", bundle: .module), call.name)
        }
    }

    // MARK: - Arg accessors

    /// Falls back to a single `seasonNumber` so the copy lists every season the model will grab.
    private func seasonNumbers() -> [Int] {
        guard case .object(let dict) = call.arguments else { return [] }
        if case .array(let arr)? = dict["seasonNumbers"] {
            let xs = arr.compactMap { v -> Int? in
                switch v {
                case .number(let n): return Int(n)
                case .string(let s): return Int(s)
                default: return nil
                }
            }
            if !xs.isEmpty { return xs.sorted() }
        }
        if let single = intArg("seasonNumber") { return [single] }
        return []
    }

    private func intArg(_ key: String) -> Int? {
        guard case .object(let dict) = call.arguments, let v = dict[key] else { return nil }
        switch v {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    private func boolArg(_ key: String) -> Bool? {
        guard case .object(let dict) = call.arguments, let v = dict[key] else { return nil }
        if case .bool(let b) = v { return b }
        return nil
    }

    private func arrayArgCount(_ key: String) -> Int {
        guard case .object(let dict) = call.arguments, case .array(let arr) = dict[key] else { return 0 }
        return arr.count
    }
}

/// Orange-shield warning card shared by chat and detail surfaces. `message` arrives
/// already localized; `confirmLabelKey` is a catalog key.
struct InlineConfirmCard: View {
    let message: Text
    let confirmLabelKey: LocalizedStringKey
    let destructive: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// Verbatim message, already localized (chat tool-call descriptions).
    init(
        message: String,
        confirmLabelKey: LocalizedStringKey = "Confirm",
        destructive: Bool = true,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.message = Text(verbatim: message)
        self.confirmLabelKey = confirmLabelKey
        self.destructive = destructive
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .scaledFont(size: 16)
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                message
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    // Custom capsules with `.contentShape` on the padded label: native styles left only the text tappable.
                    Button(role: .cancel, action: onCancel) {
                        Text("Cancel", bundle: .module)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .keyboardShortcut(.escape, modifiers: [])
                    Button(role: destructive ? .destructive : nil, action: onConfirm) {
                        Text(confirmLabelKey, bundle: .module)
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(destructive ? Color.red : Color.accentColor, in: Capsule())
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.75)
        )
    }
}

/// The app's one in-surface confirmation alert (`ConfirmCenter` and `.inlineConfirm`).
/// No shield: an alert already owns the screen; the red verb is the warning.
struct ConfirmAlertOverlay: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let confirmLabelKey: LocalizedStringKey
    let cancelLabelKey: LocalizedStringKey
    let destructive: Bool
    let suppressionLabelKey: LocalizedStringKey?
    let onConfirm: () -> Void
    let onSuppress: () -> Void
    let onCancel: () -> Void
    @State private var suppress = false

    init(
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        confirmLabelKey: LocalizedStringKey = "Confirm",
        cancelLabelKey: LocalizedStringKey = "Cancel",
        destructive: Bool = true,
        suppressionLabelKey: LocalizedStringKey? = nil,
        onConfirm: @escaping () -> Void,
        onSuppress: @escaping () -> Void = {},
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmLabelKey = confirmLabelKey
        self.cancelLabelKey = cancelLabelKey
        self.destructive = destructive
        self.suppressionLabelKey = suppressionLabelKey
        self.onConfirm = onConfirm
        self.onSuppress = onSuppress
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            // The card is small and centred in the content it interrupts; the dimming separates them.
            Rectangle()
                .fill(.black.opacity(0.32))
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
                .ignoresSafeArea()

            card
                .frame(maxWidth: 270)
                .padding(.horizontal, 24)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var card: some View {
        // Mimics the macOS 26 system alert, which can't be used: dismissing it closes the MenuBarExtra panel.
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title, bundle: .module)
                    .scaledFont(size: 13, weight: .bold)
                Text(message, bundle: .module)
                    .scaledFont(size: 13)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let suppressionLabelKey {
                Toggle(isOn: $suppress) {
                    Text(suppressionLabelKey, bundle: .module).scaledFont(size: 12)
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
            }

            HStack(spacing: 8) {
                answerButton(cancelLabelKey, weight: .medium,
                             foreground: .primary, background: Color.primary.opacity(0.1),
                             action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                answerButton(confirmLabelKey, weight: .medium,
                             foreground: destructive ? .red : .white,
                             background: destructive ? Color.red.opacity(0.22) : Color.accentColor,
                             action: {
                                 if suppress { onSuppress() }
                                 onConfirm()
                             })
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        // Liquid Glass, not a material: the alert should refract the list beneath it.
        .glassEffect(.regular, in: .rect(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.30), radius: 18, y: 4)
    }

    private func answerButton(_ key: LocalizedStringKey, weight: Font.Weight,
                              foreground: Color, background: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key, bundle: .module)
                .scaledFont(size: 13, weight: weight)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(background, in: Capsule())
    }
}
