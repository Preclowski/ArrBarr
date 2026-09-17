import SwiftUI

/// Full-width pill row used in the chat empty state under "OR ASK".
/// Tapping it injects the underlying prompt into the chat (same as
/// typing and pressing return).
public struct SuggestionPromptRow: View {
    /// Catalog key, not a `LocalizedStringKey`: the row identifies the line it
    /// is showing by it (see the cross-fade below), and `LocalizedStringKey`
    /// isn't `Hashable`.
    public let titleKey: String
    public let onTap: () -> Void

    public init(_ titleKey: String, onTap: @escaping () -> Void) {
        self.titleKey = titleKey
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack {
                // The pill stays; only the sentence inside it changes. Keyed by
                // the text and laid out in a ZStack so the outgoing and
                // incoming lines can overlap for the length of the cross-fade
                // instead of taking turns in the row's layout — which is what
                // made a changing suggestion look like a new row sliding in.
                ZStack(alignment: .leading) {
                    Text(LocalizedStringKey(titleKey), bundle: .module)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .id(titleKey)
                        .transition(.opacity)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.suggestionRow, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }
}
