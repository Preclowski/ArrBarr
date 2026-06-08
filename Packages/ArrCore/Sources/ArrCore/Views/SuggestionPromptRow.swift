import SwiftUI

/// Full-width pill row used in the chat empty state under "OR ASK".
/// Tapping it injects the underlying prompt into the chat (same as
/// typing and pressing return).
public struct SuggestionPromptRow: View {
    public let titleKey: LocalizedStringKey
    public let onTap: () -> Void

    public init(_ titleKey: LocalizedStringKey, onTap: @escaping () -> Void) {
        self.titleKey = titleKey
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack {
                Text(titleKey, bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
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
