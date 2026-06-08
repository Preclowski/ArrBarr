import SwiftUI

public struct NeedsYouSectionView: View {
    let items: [NeedsYouItem]
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    var onItemTap: ((NeedsYouItem) -> Void)? = nil

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
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(isCollapsed ? "Expand section" : "Collapse section", bundle: .module))

            if !isCollapsed {
                VStack(spacing: 4) {
                    ForEach(items) { needs in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(needs.title)
                                    .scaledFont(size: 12, weight: .medium)
                                    .lineLimit(2)
                                // Chevron telegraphs the drill-in
                                // affordance — same pattern queue /
                                // upcoming rows use.
                                LinkChevron(size: 9)
                                Spacer(minLength: 4)
                                sourceChip(needs.source)
                            }
                            Text(needs.subtitle)
                                .scaledFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            // Surface the arr's own warning descriptions
                            // — `statusMessages` already comes back as
                            // "Title — Message" lines, ready to render.
                            // Cap at 2 lines so a chatty arr (Sonarr's
                            // import warnings can pile up) doesn't
                            // dominate the popover.
                            ForEach(Array(needs.detailLines.prefix(2).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .scaledFont(size: 10)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        // Match the queue / upcoming row indent (12pt
                        // horizontal) — the previous 28pt leading hung
                        // items under the section icon, which read as
                        // inconsistent next to the other sections.
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { onItemTap?(needs) }
                        #if os(macOS)
                        .onHover { hovering in
                            if onItemTap != nil {
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                        }
                        #endif
                        .help(Text("Open in browser", bundle: .module))
                        // Drill-in chevron brightens on row hover.
                        .linkRowHover()
                    }
                }
            }
        }
    }

    private func sourceChip(_ source: QueueItem.Source) -> some View {
        HStack(spacing: 3) {
            ServiceIcon(source: source, size: 9)
            Text(source.displayName)
                .scaledFont(size: 10, weight: .medium)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                .fill(Color.primary.opacity(0.07))
        )
        .padding(.top, 3)
    }
}
