import SwiftUI

/// Chat card for a single download-queue item.
///
/// - **Upgrade rows** render a side-by-side comparison: the current library
///   file (left) vs the incoming release (right), with improved dimensions
///   highlighted in green and dropped custom formats struck through.
/// - **Plain rows** render a compact status + progress strip.
///
/// The LLM writes the "why it's better" narrative above this card from the
/// tool's text output; this view is the at-a-glance visual.
struct QueueComparisonCard: View {
    let item: QueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if item.isUpgrade {
                UpgradeDiffView(item: item)
            } else {
                progressStrip
            }
        }
        .padding(10)
        .frame(width: item.isUpgrade ? 300 : 220, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .contentShape(Rectangle())
        .onTapGesture {
            guard let entityId = item.entityId else { return }
            DetailRequest.post(
                DetailRequest.syntheticItem(
                    source: item.source,
                    entityId: entityId,
                    title: item.title,
                    posterURL: item.posterURL,
                    posterRequiresAuth: item.posterRequiresAuth
                )
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ServiceIcon(source: item.source, size: 10)
                    .foregroundStyle(.secondary)
                if item.isUpgrade {
                    // Use the shared badge so the chat diff's "Upgrade"
                    // label matches the indigo pill used on queue rows,
                    // tooltips and detail surfaces — was a one-off green
                    // capsule that read as a different element.
                    MediaBadgeCluster(isUpgrade: true)
                }
                Spacer(minLength: 0)
                Text("\(Int((item.progress * 100).rounded()))%")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
            Text(item.title)
                .scaledFont(size: 13, weight: .semibold)
                .lineLimit(2)
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Plain row

    private var progressStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.status.displayName)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * item.progress))
                }
            }
            .frame(height: 5)
        }
    }
}
