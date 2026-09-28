import SwiftUI

/// With `existingFormats`, formats the existing file lacks render green, so
/// the diff lives in one strip.
struct CustomFormatChips: View {
    let formats: [String]
    let score: Int
    var existingFormats: [String]? = nil

    var body: some View {
        let oldSet: Set<String> = existingFormats.map(Set.init) ?? []
        let highlightAdded = existingFormats != nil
        TooltipFlowLayout(spacing: 4) {
            ForEach(formats, id: \.self) { f in
                let isAdded = highlightAdded && !oldSet.contains(f)
                TagChip(text: f, color: isAdded ? .green : .primary)
            }
            if score != 0 {
                ScoreChip(score: score)
            }
        }
    }
}
