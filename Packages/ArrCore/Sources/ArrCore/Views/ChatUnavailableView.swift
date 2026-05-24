import SwiftUI

public struct ChatUnavailableView: View {
    public enum Reason { case osTooOld, mcpNotConfigured, providerUnavailable }
    let reason: Reason
    let onOpenSettings: (() -> Void)?

    public init(reason: Reason, onOpenSettings: (() -> Void)? = nil) {
        self.reason = reason
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .scaledFont(size: 28, weight: .light)
                .foregroundStyle(.tertiary)
            Text(title, bundle: .module)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if reason == .mcpNotConfigured, let onOpenSettings {
                Button { onOpenSettings() } label: { Text("Open Settings…", bundle: .module) }
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch reason {
        case .osTooOld: return "exclamationmark.triangle"
        case .mcpNotConfigured: return "server.rack"
        case .providerUnavailable: return "sparkles"
        }
    }
    private var title: LocalizedStringKey {
        switch reason {
        case .osTooOld: return "Chat requires macOS 26 with Apple Intelligence."
        case .mcpNotConfigured: return "Set MCP server URL in Settings to start chatting."
        case .providerUnavailable: return "Apple Intelligence is unavailable. Try turning it on in System Settings."
        }
    }
}
