import SwiftUI

struct QueueSectionView: View {
    let title: String
    let symbol: String
    let items: [QueueItem]
    @ObservedObject var viewModel: QueueViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(items.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)

            if items.isEmpty {
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
}
