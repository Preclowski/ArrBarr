import SwiftUI

/// Tertiary "couldn't load" line inside the edit panel, which stays open over the failure.
struct LoadErrorLine: View {
    let message: String

    var body: some View {
        Text(message)
            .scaledFont(size: 11)
            .foregroundStyle(.tertiary)
    }
}
