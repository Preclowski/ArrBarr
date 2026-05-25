import SwiftUI

public struct DiscoverTabView: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .scaledFont(size: 28, weight: .light)
                .foregroundStyle(.tertiary)
            Text("Discover", bundle: .module)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
