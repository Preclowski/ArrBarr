import SwiftUI

// MARK: - Tab pill background

struct TabPillBackground: View {
    var body: some View {
        // Inside the outer glass capsule, and glass-on-glass would vanish.
        Capsule()
            .fill(Color.primary.opacity(0.14))
    }
}
