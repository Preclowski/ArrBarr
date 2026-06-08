import SwiftUI

struct UpcomingTabContent: View {
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        ScrollView {
            Group {
                if viewModel.upcoming.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .scaledFont(size: 24, weight: .light)
                            .foregroundStyle(.tertiary)
                        Text("Nothing upcoming", bundle: .module)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedUpcoming, id: \.date) { group in
                            Text(group.label)
                                .scaledFont(size: 11, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, group.isFirst ? 8 : 14)
                                .padding(.bottom, 4)

                            ForEach(group.items) { item in
                                UpcomingRowView(item: item)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
    }

    private var groupedUpcoming: [UpcomingGroup] {
        let calendar = Calendar.current
        var groups: [UpcomingGroup] = []
        var current: (date: DateComponents, items: [UpcomingItem])?

        for item in viewModel.upcoming {
            let dc = calendar.dateComponents([.year, .month, .day], from: item.airDate)
            if let c = current, c.date == dc {
                current?.items.append(item)
            } else {
                if let c = current, let first = c.items.first {
                    let y = c.date.year ?? 0, m = c.date.month ?? 0, d = c.date.day ?? 0
                    groups.append(UpcomingGroup(
                        date: "\(y)-\(m)-\(d)",
                        label: first.airDateFormatted(locale: configStore.currentLocale),
                        items: c.items,
                        isFirst: groups.isEmpty
                    ))
                }
                current = (dc, [item])
            }
        }
        if let c = current, let first = c.items.first {
            let y = c.date.year ?? 0, m = c.date.month ?? 0, d = c.date.day ?? 0
            groups.append(UpcomingGroup(
                date: "\(y)-\(m)-\(d)",
                label: first.airDateFormatted(locale: configStore.currentLocale),
                items: c.items,
                isFirst: groups.isEmpty
            ))
        }
        return groups
    }
}

private struct UpcomingGroup {
    let date: String
    let label: String
    let items: [UpcomingItem]
    let isFirst: Bool
}
