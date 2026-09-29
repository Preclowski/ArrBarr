import SwiftUI

struct SuggestionPromptRow: View {
    /// The row keys its cross-fade on it, and `LocalizedStringKey` isn't `Hashable`.
    let titleKey: String
    let onTap: () -> Void

    init(_ titleKey: String, onTap: @escaping () -> Void) {
        self.titleKey = titleKey
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) {
            HStack {
                // Keyed by text in a ZStack so outgoing and incoming lines overlap during the cross-fade
                // instead of reading as a new row sliding in.
                ZStack(alignment: .leading) {
                    Text(LocalizedStringKey(titleKey), bundle: .module)
                        .scaledFont(size: 13)
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
