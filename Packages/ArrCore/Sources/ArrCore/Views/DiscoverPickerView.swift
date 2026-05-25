import SwiftUI

// MARK: - DiscoverPickerView

/// LLM-only Discover picker. A single multi-line text field bound to
/// `viewModel.moodText` is the entire input surface. Submit (Enter or
/// the Discover button) drives the parent's `onSubmit` callback which
/// flips the VM into `.tinder` and triggers a reshuffle.
public struct DiscoverPickerView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let onSubmit: () -> Void

    @FocusState private var inputFocused: Bool

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                onSubmit: @escaping () -> Void) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Text("What do you feel like watching?", bundle: .module)
                .scaledFont(size: 18, weight: .semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            TextField(
                "",
                text: $viewModel.moodText,
                prompt: Text("Describe a mood, a vibe, a director, anything", bundle: .module),
                axis: .vertical
            )
            .lineLimit(2...5)
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .scaledFont(size: 14)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
            )
            .padding(.horizontal, 24)
            .onSubmit(submitIfValid)

            Button(action: submitIfValid) {
                Text("Discover", bundle: .module)
                    .scaledFont(size: 14, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(submitDisabled || !llmAvailable)
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { inputFocused = true }
    }

    private var submitDisabled: Bool {
        viewModel.moodText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitIfValid() {
        guard !submitDisabled, llmAvailable else { return }
        viewModel.userSubmittedMood()
        onSubmit()
    }
}
