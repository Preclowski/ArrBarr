import SwiftUI

/// "Test Connection" button for Settings (OpenAI / TMDB). Same chrome and label
/// as the arr / download-client test in `ServiceFields` so every credential
/// field tests the same way: a `GlassButtonStyle` button + an inline ✓ / ✗.
struct ApiKeyTestButton: View {
    /// Validation work — throws on an invalid key / unreachable endpoint.
    let test: () async throws -> Void

    @State private var state: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, success
        case failure(String)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { Task { await run() } } label: {
                Text("Test Connection", bundle: .module)
            }
            .modifier(GlassButtonStyle())
            .controlSize(.small)
            .disabled(state == .testing)

            switch state {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
            case .success:
                Label { Text("Connected", bundle: .module) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            case .failure(let msg):
                Label { Text(verbatim: msg) } icon: { Image(systemName: "xmark.circle.fill") }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(msg)
            }
        }
    }

    @MainActor
    private func run() async {
        state = .testing
        do {
            try await test()
            state = .success
        } catch {
            state = .failure(message(for: error))
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
