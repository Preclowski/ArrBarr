import SwiftUI

/// iOS keyboard / autofill / capitalisation hints per field type; no-op on macOS.
public extension View {
    func urlField() -> some View {
        self
            .autocorrectionDisabled(true)
            #if os(iOS)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            #endif
    }

    func usernameField() -> some View {
        self
            .autocorrectionDisabled(true)
            #if os(iOS)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            #endif
    }

    func passwordField() -> some View {
        self
            #if os(iOS)
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            #endif
    }

    /// `.oneTimeCode` keeps iOS from offering saved passwords for a pasted key.
    func apiKeyField() -> some View {
        self
            .autocorrectionDisabled(true)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    func technicalField() -> some View {
        self
            .autocorrectionDisabled(true)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }
}
