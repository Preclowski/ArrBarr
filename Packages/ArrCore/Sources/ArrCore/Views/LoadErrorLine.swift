import SwiftUI

/// Tertiary "couldn't load details" line shown at the bottom of the
/// Radarr / Sonarr / Lidarr detail panels. Each panel carried an identical
/// copy; this is the single source.
struct LoadErrorLine: View {
    let message: String

    var body: some View {
        Text(message)
            .scaledFont(size: 11)
            .foregroundStyle(.tertiary)
    }
}
