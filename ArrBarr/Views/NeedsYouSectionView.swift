import SwiftUI

struct NeedsYouSectionView: View {
    let items: [NeedsYouItem]
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    var onItemTap: ((NeedsYouItem) -> Void)? = nil
    @State private var hoveredID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 10)
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
                Text("Needs you")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(items.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture { onToggleCollapse() }

            if !isCollapsed {
                VStack(spacing: 4) {
                    ForEach(items) { needs in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(needs.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                sourceChip(needs.source)
                            }
                            Text(needs.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.leading, 28)
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                        .background(
                            hoveredID == needs.id
                                ? Color.primary.opacity(0.06)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onItemTap?(needs) }
                        .onHover { hovering in
                            hoveredID = hovering ? needs.id : nil
                            if onItemTap != nil {
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                        }
                        .help("Open in browser")
                    }
                }
            }
        }
    }

    private func sourceChip(_ source: QueueItem.Source) -> some View {
        HStack(spacing: 3) {
            Image(systemName: source.symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(source.displayName)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.07))
        )
    }
}
