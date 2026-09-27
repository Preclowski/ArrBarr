import SwiftUI

/// Upgrade badge in the movie detail header.
struct ListingBadgesView: View {
    let item: QueueItem

    /// "New" is implied by the missing file banner, and the client shows in `ProgressLine`.
    var body: some View {
        if item.isUpgrade {
            HStack(spacing: 4) {
                Text("detail.upgrade.button", bundle: .module)
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(Color.indigo)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .chipOutline(.indigo)
                Spacer()
            }
        }
    }
}
