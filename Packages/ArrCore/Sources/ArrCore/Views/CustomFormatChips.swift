import SwiftUI

/// Custom-format tag chips with optional score, wrapping to multiple lines
/// when needed. Used in the detail download section to mirror the chip strip
/// shown on listing rows.
struct CustomFormatChips: View {
    let formats: [String]
    let score: Int
    public var body: some View {
        TooltipFlowLayout(spacing: 4) {
            ForEach(formats, id: \.self) { TagChip(text: $0) }
            if score != 0 {
                let sign = score > 0 ? "+" : ""
                TagChip(text: "\(sign)\(score)", color: score > 0 ? .green : .red)
            }
        }
    }
}
