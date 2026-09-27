import SwiftUI

#if os(macOS)
    /// Its own view to keep `tonightSection` under the type-check warn threshold.
struct TonightBannerRow: View {
    let item: UpcomingItem
    let timeString: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(timeString)
                    .scaledFont(size: 11, weight: .medium, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                ServiceIcon(source: item.source, size: 10)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .scaledFont(size: 11)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.entityId == nil)
        .upcomingTooltip(item: item)
    }
}
#endif
