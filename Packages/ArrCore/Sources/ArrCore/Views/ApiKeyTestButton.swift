import SwiftUI
import MediaKit

/// Same chrome as the arr / download-client test in `ServiceFields`.
struct ApiKeyTestButton: View {
    let test: () async throws -> Void
    /// When set, the result is written to the shared `ConnectionHealth` and a status dot is shown.
    var service: MonitoredService? = nil

    @State private var state: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, success
        case failure(String)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let service {
                ConnectionStatusDot(service: service)
            }
            Button { Task { await run() } } label: {
                Text("queue.testConnection.button", bundle: .module)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state == .testing)

            switch state {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
            case .success:
                Label { Text("settings.connected.button", bundle: .module) } icon: { Image(systemName: "checkmark.circle.fill") }
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
            if let service { ConnectionHealth.shared.forceOK(service, detail: nil) }
        } catch {
            let msg = message(for: error)
            state = .failure(msg)
            if let service { ConnectionHealth.shared.forceDown(service, message: msg) }
        }
    }

    private func message(for error: Error) -> String {
        if case MediaKitError.unauthorized = error { return String(localized: "settings.invalidKey.button", bundle: .module) }
        return error.localizedDescription
    }
}
