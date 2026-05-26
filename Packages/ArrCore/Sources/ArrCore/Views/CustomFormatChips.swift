import SwiftUI

/// Custom-format tag chips with optional score, wrapping to multiple lines
/// when needed. Used in the detail download section to mirror the chip strip
/// shown on listing rows.
///
/// When `existingFormats` is non-nil, formats that aren't in the existing
/// file render as green (added) — the diff is encoded in the strip itself
/// so the host doesn't have to render the same chip twice (once in white
/// "new spec", once in the green "+ added" row underneath).
struct CustomFormatChips: View {
    let formats: [String]
    let score: Int
    var existingFormats: [String]? = nil

    public var body: some View {
        let oldSet: Set<String> = existingFormats.map(Set.init) ?? []
        let highlightAdded = existingFormats != nil
        TooltipFlowLayout(spacing: 4) {
            ForEach(formats, id: \.self) { f in
                let isAdded = highlightAdded && !oldSet.contains(f)
                TagChip(text: f, color: isAdded ? .green : .primary)
            }
            if score != 0 {
                let sign = score > 0 ? "+" : ""
                TagChip(text: "\(sign)\(score)", color: score > 0 ? .green : .red)
            }
        }
    }
}
