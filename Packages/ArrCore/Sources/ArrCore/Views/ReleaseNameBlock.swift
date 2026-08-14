import SwiftUI

/// Monospaced release-name line, with an optional `└─` sub-line for the file
/// it replaces. Shared by `EpisodeDetailOverlay` and `DownloadSection` for
/// the "single release name" (non-diff) case. The full side-by-side upgrade
/// comparison uses `UpgradeDiffView` instead, which renders its file names
/// untruncated.
struct ReleaseNameBlock: View {
    let release: String?
    var existing: String? = nil

    var body: some View {
        if let release, !release.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                // Colour rule: the new (or only) filename is primary; the
                // replaced one below drops to secondary.
                Text(release)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let existing, !existing.isEmpty, existing != release {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(.tertiary)
                        Text(existing)
                            .scaledFont(size: 11, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
