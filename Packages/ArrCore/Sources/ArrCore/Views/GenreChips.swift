import SwiftUI

struct GenreChips: View {
    let genres: [String]
    public var body: some View {
        TooltipFlowLayout(spacing: 4) {
            ForEach(genres, id: \.self) { g in
                Text(g)
                    .scaledFont(size: 9, weight: .medium)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
        }
        .padding(.top, 2)
    }
}
