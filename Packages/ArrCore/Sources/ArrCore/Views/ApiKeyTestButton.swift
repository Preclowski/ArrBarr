import SwiftUI

/// A "Test key" button for Settings that runs an async validation closure and
/// shows the result inline: spinner while testing, a green check on success, a
/// red message on failure. Used to verify the OpenAI and TMDB credentials.
struct ApiKeyTestButton: View {
    /// Validation work — throws on an invalid key / unreachable endpoint.
    let test: () async throws -> Void

    @State private var state: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, ok
        case fail(String)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await run() }
            } label: {
                Text("Test key", bundle: .module)
            }
            .disabled(state == .testing)

            switch state {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
            case .ok:
                Label { Text("Works", bundle: .module) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .foregroundStyle(.green)
                    .font(.caption)
            case .fail(let msg):
                Label { Text(verbatim: msg) } icon: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }

    @MainActor
    private func run() async {
        state = .testing
        do {
            try await test()
            state = .ok
        } catch {
            state = .fail(message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        let desc = (error as NSError).localizedDescription
        if desc.localizedCaseInsensitiveContains("401")
            || desc.localizedCaseInsensitiveContains("403")
            || desc.localizedCaseInsensitiveContains("unauthor") {
            return String(localized: "Invalid key", bundle: .module)
        }
        return String(localized: "Failed — check key & URL", bundle: .module)
    }
}
