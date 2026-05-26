import SwiftUI

public struct ExpandableOverview: View {
    let text: String
    @State private var expanded = false
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            if !expanded && text.count > 220 {
                Button {
                    withAnimation(.smooth(duration: 0.18)) { expanded = true }
                } label: {
                    // Disclosure now reads as a control — small
                    // chevron + medium weight + accent colour so it
                    // stops blending into the overview text it sits
                    // under. .secondary was too tonally similar.
                    HStack(spacing: 3) {
                        Text("Show more", bundle: .module)
                            .scaledFont(size: 11, weight: .medium)
                        Image(systemName: "chevron.down")
                            .scaledFont(size: 9, weight: .semibold)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
