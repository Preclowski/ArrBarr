import SwiftUI

/// The collapsible "Needs you" section HEADER, rendered as its own List row by
/// QueueListView (with each item a SIBLING row) so the chevron lines up with —
/// and the collapse animation matches — every other section header. Uses the
/// shared `QueueHeaderRow`, so its chevron / icon slot / padding are byte-for-byte
/// the arr + Next-week headers.
struct NeedsYouHeader: View {
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        QueueHeaderRow(
            // Grey (.secondary) like the arr ServiceIcons — a section glyph, not
            // an alarm. Size 11 (not 12): the filled bubble reads heavier than the
            // arr icons / moon, so it's nudged down to match their weight.
            icon: AnyView(
                Image(systemName: "exclamationmark.bubble.fill")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            ),
            title: String(localized: "queue.needsYou.button", bundle: .module),
            count: count,
            collapsed: isCollapsed,
            onToggle: onToggle
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(isCollapsed ? "Expand section" : "Collapse section", bundle: .module))
    }
}

/// A single "Needs you" entry, rendered as its own List row by QueueListView.
struct NeedsYouRow: View {
    let needs: NeedsYouItem
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                // No leading severity icon — the title text alone carries the
                // message (the severity still drives merge grouping in the model).
                Text(needs.title)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(2)
                // "×N" when this row collapses several identical entries (e.g. one
                // manual-import warning per episode of a season pack).
                if needs.count > 1 {
                    Text(verbatim: "×\(needs.count)")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // Drill-in chevron; non-arr connection issues have nowhere to
                // drill, so no chevron.
                if needs.service == nil {
                    LinkChevron(size: 9)
                }
                Spacer(minLength: 4)
                sourceChip
            }
            // Status name for a queue item; empty (hidden) for arr/service issues
            // whose message is the title.
            if !needs.subtitle.isEmpty {
                Text(needs.subtitle)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Cap at 2 lines so a chatty arr doesn't dominate the popover.
            ForEach(Array(needs.detailLines.prefix(2).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Indent the content under the section icon (past the chevron column),
        // matching the "Next week" banner's item indent.
        .padding(.leading, QueueHeaderMetrics.contentIndent)
        .padding(.trailing, Tokens.Spacing.queueRowH)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        #if os(macOS)
        .onHover { hovering in
            if onTap != nil {
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        #endif
        .help(Text("detail.openInBrowser.button", bundle: .module))
        // Drill-in chevron brightens on row hover.
        .linkRowHover()
    }

    @ViewBuilder
    private var sourceChip: some View {
        HStack(spacing: 3) {
            chipIcon
            Text(chipLabel)
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

    @ViewBuilder
    private var chipIcon: some View {
        if let source = needs.source {
            ServiceIcon(source: source, size: 9)
        } else if let kind = needs.service?.serviceKind {
            ServiceIcon(kind: kind, size: 9)
        } else {
            // AI services (OpenAI / TMDB) have no brand asset.
            Image(systemName: "sparkles")
                .scaledFont(size: 9, weight: .semibold)
        }
    }

    private var chipLabel: String {
        needs.source?.displayName ?? needs.service?.displayName ?? needs.title
    }
}
