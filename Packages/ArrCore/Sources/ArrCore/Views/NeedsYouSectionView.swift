import SwiftUI

public struct NeedsYouSectionView: View {
    let items: [NeedsYouItem]
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    var onItemTap: ((NeedsYouItem) -> Void)? = nil
    @State private var hoveredID: String?

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 10)
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
                Text("Needs you", bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(items.count)")
                    .scaledFont(size: 11)
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
                                    .scaledFont(size: 12, weight: .medium)
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                sourceChip(needs.source)
                            }
                            Text(needs.subtitle)
                                .scaledFont(size: 11)
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
                            #if os(macOS)
                            if onItemTap != nil {
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                            #endif
                        }
                        .help(Text("Open in browser", bundle: .module))
                    }
                }
            }
        }
    }

    private func sourceChip(_ source: QueueItem.Source) -> some View {
        HStack(spacing: 3) {
            Image(systemName: source.symbol)
                .scaledFont(size: 9, weight: .semibold)
            Text(source.displayName)
                .scaledFont(size: 10, weight: .medium)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.07))
        )
        .padding(.top, 3)
    }
}
