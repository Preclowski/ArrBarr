import SwiftUI

/// Full-width existing-file banner for Radarr details. Sits between the
/// header card and the overview so the chips have room to breathe.
/// "Listing" badges mirroring the queue row's title chips: Upgrade/New
/// capsule + download-client capsule. Shown in the movie detail header
/// (under the ratings) so the user knows which client is grinding away
/// without having to scroll to the download section.
public struct ListingBadgesView: View {
    let item: QueueItem

    /// Only the Upgrade pill, and only when the row is actually an upgrade.
    /// "New" is implicit (no existing-file banner = brand new download), and
    /// the download client already shows up in `ProgressLine` below — both
    /// previously duplicated here.
    public var body: some View {
        if item.isUpgrade {
            HStack(spacing: 4) {
                Text("detail.upgrade.button", bundle: .module)
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(Color.indigo)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chip).stroke(Color.indigo.opacity(0.30), lineWidth: 0.75))
                Spacer()
            }
        }
    }
}
