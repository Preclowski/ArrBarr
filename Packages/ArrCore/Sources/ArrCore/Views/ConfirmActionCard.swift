import SwiftUI

/// In-chat banner that gates a destructive LLM tool call. Shows a
/// human-readable description of what's about to happen — not the
/// raw JSON args, which read as line-noise even for power users —
/// then Confirm / Cancel. Cancel returns "(cancelled by user)" so
/// the model can adjust its plan.
///
/// The description is tool-specific; we map known tool names to a
/// natural-language template so the user sees "Monitor season 4 and
/// start search" instead of `{"seasonNumber":4,"seriesId":241,…}`.
/// For unknown tools we fall back to the tool name plus arg count
/// — still cleaner than a JSON dump.
public struct ConfirmActionCard: View {
    let call: ToolCall
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public init(call: ToolCall, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.call = call
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        InlineConfirmCard(
            message: humanDescription,
            confirmLabelKey: "Confirm",
            onConfirm: onConfirm,
            onCancel: onCancel
        )
    }

    /// Human-readable summary of what the tool will do. Switches on
    /// tool name; arg substitutions use `String(format:)` so the
    /// localized template gets the numbers inlined.
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

    /// Seasons targeted by `sonarr_monitor_season`. Reads the
    /// `seasonNumbers` array, falling back to a legacy single
    /// `seasonNumber`, so the gate copy lists every season the model
    /// is about to grab ("season(s) 10 and 11") instead of just one.
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

/// Common destructive-action warning card. Same orange-shielded chrome
/// the chat uses to gate tool calls — reused inline / in popovers on
/// detail surfaces so the user always sees the same shape when they're
/// about to do something irreversible (search consumes indexer quota,
/// remove deletes the download client entry).
///
/// `message` is a fully-formed sentence (already localized by the
/// caller). `confirmLabelKey` is a localization key from the module's
/// strings catalogue — defaults to "Confirm", but the destructive flows
/// in season/episode rows pass "Search" / "Remove" to mirror the verb in
/// their alert message.
public struct InlineConfirmCard: View {
    /// Optional headline above the message. nil keeps the legacy
    /// "single line message + buttons" chat-tool-gate shape.
    let title: LocalizedStringKey?
    let message: Text
    let confirmLabelKey: LocalizedStringKey
    let cancelLabelKey: LocalizedStringKey
    let destructive: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// Verbatim message — used by chat for tool-call descriptions
    /// (already localized strings, no key lookup).
    public init(
        message: String,
        confirmLabelKey: LocalizedStringKey = "Confirm",
        destructive: Bool = true,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = nil
        self.message = Text(verbatim: message)
        self.confirmLabelKey = confirmLabelKey
        self.cancelLabelKey = "Cancel"
        self.destructive = destructive
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    /// Localized title + message — used by `ConfirmCenter`-driven
    /// flows (queue trash, settings reset, etc).
    public init(
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        confirmLabelKey: LocalizedStringKey = "Confirm",
        cancelLabelKey: LocalizedStringKey = "Cancel",
        destructive: Bool = true,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = Text(message, bundle: .module)
        self.confirmLabelKey = confirmLabelKey
        self.cancelLabelKey = cancelLabelKey
        self.destructive = destructive
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .scaledFont(size: 16)
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title, bundle: .module)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(.primary)
                }
                message
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    // Custom capsules with the full padded area as the hit target
                    // (`.contentShape` on the padded label + `.plain` style) — the
                    // native button styles left only the text tappable here.
                    Button(role: .cancel, action: onCancel) {
                        Text(cancelLabelKey, bundle: .module)
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

/// The app's one confirmation alert: a dimming scrim and a centred card with a
/// title, a sentence and the two answers. Every modal yes/no inside a surface
/// renders through this — the queue's `ConfirmCenter` requests and the detail
/// surfaces' `.inlineConfirm` — so a confirmation reads the same wherever it is
/// raised, and no caller styles its own.
///
/// Deliberately plain: no orange shield (that belongs to `InlineConfirmCard`,
/// which sits *inside* chat content and has to announce itself against the
/// message flow). An alert already owns the screen; the destructive verb on the
/// red button is the warning.
public struct ConfirmAlertOverlay: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let confirmLabelKey: LocalizedStringKey
    let cancelLabelKey: LocalizedStringKey
    let destructive: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public init(
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        confirmLabelKey: LocalizedStringKey = "Confirm",
        cancelLabelKey: LocalizedStringKey = "Cancel",
        destructive: Bool = true,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmLabelKey = confirmLabelKey
        self.cancelLabelKey = cancelLabelKey
        self.destructive = destructive
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        ZStack {
            // Heavier than the old sheet's scrim: the card is small and sits in
            // the middle of the content it interrupts, so the dimming is what
            // separates them.
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
        // Laid out like the macOS 26 system alert — leading text, tinted rather
        // than filled destructive answer — since the real one can't be used:
        // dismissing it closes the MenuBarExtra panel underneath.
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

            HStack(spacing: 8) {
                answerButton(cancelLabelKey, weight: .medium,
                             foreground: .primary, background: Color.primary.opacity(0.1),
                             action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                answerButton(confirmLabelKey, weight: .medium,
                             foreground: destructive ? .red : .white,
                             background: destructive ? Color.red.opacity(0.22) : Color.accentColor,
                             action: onConfirm)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        // Real Liquid Glass, not a material: the alert floats over the list and
        // should refract it, which a blurred grey plate cannot do.
        .glassEffect(.regular, in: .rect(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.30), radius: 18, y: 4)
    }

    /// Equal-width capsules — an alert's two answers carry the same weight in
    /// the layout even when one of them is the dangerous one.
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
