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
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chip).stroke(Color.primary.opacity(0.45), lineWidth: 0.75))
            }
        }
        .padding(.top, 2)
    }
}
