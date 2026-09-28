import SwiftUI

struct GenreChips: View {
    let genres: [String]
    @Environment(\.locale) private var locale

    var body: some View {
        TooltipFlowLayout(spacing: 4) {
            ForEach(genres, id: \.self) { g in
                Text(verbatim: GenreName.localized(g, locale: locale))
                    .scaledFont(size: 9, weight: .medium)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .chipOutline(.primary, opacity: 0.22)
            }
        }
        .padding(.top, 2)
    }
}
