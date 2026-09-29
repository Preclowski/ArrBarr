import SwiftUI

/// Its own List row (items are sibling rows) on the shared `QueueHeaderRow`, so chevron and
/// collapse animation match the other section headers.
struct NeedsYouHeader: View {
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        QueueHeaderRow(
            // Size 11: the filled bubble reads heavier than the arr icons.
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

struct NeedsYouRow: View {
    let needs: NeedsYouItem
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(needs.title)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(2)
                // Several identical entries collapsed, e.g. one manual-import warning per episode of a pack.
                if needs.count > 1 {
                    Text(verbatim: "×\(needs.count)")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if needs.service == nil {
                    LinkChevron(size: 9)
                }
                Spacer(minLength: 4)
                sourceChip
            }
            if !needs.subtitle.isEmpty {
                Text(needs.subtitle)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ForEach(Array(needs.detailLines.prefix(2).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, QueueHeaderMetrics.contentIndent)
        .padding(.trailing, Tokens.Spacing.queueRowH)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        #if os(macOS)
        .pointerStyle(onTap != nil ? .link : nil)
        #endif
        .help(Text("detail.openInBrowser.button", bundle: .module))
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
            Image(systemName: "sparkles")
                .scaledFont(size: 9, weight: .semibold)
        }
    }

    private var chipLabel: String {
        needs.source?.displayName ?? needs.service?.displayName ?? needs.title
    }
}
