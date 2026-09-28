import SwiftUI

/// Internal: the media-server pane in another file uses it.
struct ProLockOverlay: View {
    @ObservedObject private var store = StoreManager.shared
    let feature: ProFeature
    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
            VStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.title2).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button { store.gate(feature) } label: {
                    Text("settings.unlockArrbarrPro.button", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.gate(feature) }
    }
}
