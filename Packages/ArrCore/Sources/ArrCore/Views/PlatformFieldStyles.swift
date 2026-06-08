import SwiftUI

/// Text-field modifiers that apply the right iOS keyboard / autofill /
/// capitalisation hints per field type. No-op on macOS (the system
/// keyboard concepts don't apply), but the call site stays clean
/// instead of sprouting `#if os(iOS)` everywhere.
public extension View {
    /// URL field — `.URL` keyboard, no autocorrect, no capitalisation,
    /// AutoFill hint set so the system can fill known endpoints.
    func urlField() -> some View {
        self
            .autocorrectionDisabled(true)
            #if os(iOS)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            #endif
    }

    /// Username field — defaults to plain text, no caps, AutoFill for
    /// usernames.
    func usernameField() -> some View {
        self
            .autocorrectionDisabled(true)
            #if os(iOS)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            #endif
    }

    /// Password field — wraps a `SecureField`. Sets AutoFill hint so
    /// iOS Keychain offers stored credentials.
    func passwordField() -> some View {
        self
            #if os(iOS)
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            #endif
    }

    /// API key / token — opaque secret. No autocorrect, no caps,
    /// AutoFill = .oneTimeCode keeps the system from offering normal
    /// passwords (different shape than what the user wants to paste).
    func apiKeyField() -> some View {
        self
            .autocorrectionDisabled(true)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    /// Technical identifier (model name, slug, etc.) — no autocorrect,
    /// no capitalisation, default keyboard.
    func technicalField() -> some View {
        self
            .autocorrectionDisabled(true)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }
}
