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
                return String(format: String(localized: "Monitor season(s) %@ and start search.", bundle: .module), joined)
            } else {
                return String(format: String(localized: "Stop monitoring season(s) %@.", bundle: .module), joined)
            }
        case "sonarr_search_episodes":
            let count = arrayArgCount("episodeIds")
            return String(format: String(localized: "Search %lld episode(s).", bundle: .module), count)
        case "radarr_search_movie":
            return String(localized: "Search for this movie.", bundle: .module)
        case "lidarr_monitor_album":
            let state = boolArg("state") ?? true
            if state {
                return String(localized: "Monitor this album and start search.", bundle: .module)
            } else {
                return String(localized: "Stop monitoring this album.", bundle: .module)
            }
        case "lidarr_search_album":
            return String(localized: "Search for this album.", bundle: .module)
        default:
            return String(format: String(localized: "Run %@.", bundle: .module), call.name)
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
                    Button(role: .cancel, action: onCancel) {
                        Text(cancelLabelKey, bundle: .module)
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    Button(role: destructive ? .destructive : nil, action: onConfirm) {
                        Text(confirmLabelKey, bundle: .module)
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .modifier(GlassProminentButtonStyle())
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

/// Modal confirmation — scrim + bottom-pinned sheet card. Distinct
/// styling from the chat-inline `InlineConfirmCard` (which uses
/// orange-tinted bg because it lives inside chat content): the modal
/// gets a SOLID material card so it visually separates from whatever
/// row / text it overlays.
public struct ModalConfirmOverlay: View {
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
        ZStack(alignment: .bottom) {
            // Strong scrim — separates the card from content behind.
            // Chat usage shows the same card without scrim (inline).
            Rectangle()
                .fill(.black.opacity(0.55))
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
                .ignoresSafeArea()

            // Re-use the chat-tool-gate card verbatim. One component,
            // one visual language. The card's orange-tint + shield
            // already reads as "attention" inline; over a scrim it
            // reads as "modal".
            InlineConfirmCard(
                title: title,
                message: message,
                confirmLabelKey: confirmLabelKey,
                cancelLabelKey: cancelLabelKey,
                destructive: destructive,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
            .shadow(color: .black.opacity(0.30), radius: 16, y: -2)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
