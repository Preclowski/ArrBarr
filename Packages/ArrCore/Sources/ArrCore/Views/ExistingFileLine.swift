import SwiftUI

/// Compact one-line summary of the existing file an item would replace.
/// Used in Radarr's header card under the rating chips.
struct ExistingFileLine: View {
    let item: QueueItem

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.doc")
                    .scaledFont(size: 9)
                    .foregroundStyle(.indigo)
                Text("Existing", bundle: .module)
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.indigo)
                if let q = item.existingQuality, !q.isEmpty {
                    Text(q)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                if let size = item.existingSize, size > 0 {
                    SeparatorDot()
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                if let s = item.existingCustomFormatScore, s != 0 {
                    SeparatorDot()
                    let sign = s > 0 ? "+" : ""
                    Text(verbatim: "\(sign)\(s)")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(s > 0 ? Color.green : Color.red)
                }
            }
            if !item.existingCustomFormats.isEmpty {
                TooltipFlowLayout(spacing: 3) {
                    ForEach(item.existingCustomFormats, id: \.self) { TagChip(text: $0) }
                }
            }
        }
    }
}
