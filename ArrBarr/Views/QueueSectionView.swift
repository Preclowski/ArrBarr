import SwiftUI

struct QueueSectionView: View {
    let title: String
    let symbol: String
    let items: [QueueItem]
    var error: String?
    var health: [ArrHealthRecord] = []
    @ObservedObject var viewModel: QueueViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if error == nil {
                    Text("\(items.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                if !health.isEmpty {
                    healthBadge
                }
                Spacer()
            }
            .padding(.horizontal, 12)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else if items.isEmpty {
                Text("Queue empty")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        QueueRowView(item: item, viewModel: viewModel)
                    }
                }
            }
        }
    }

    private var healthBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.orange)
            .help(health.compactMap(\.message).joined(separator: "\n"))
    }
}
