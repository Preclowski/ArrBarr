import SwiftUI

/// The ✕ in a modal panel's header; Escape triggers it.
struct PanelCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help(Text("Cancel", bundle: .module))
        .accessibilityLabel(Text("Cancel", bundle: .module))
    }
}
