import SwiftUI

/// Per-track detail — the audio counterpart of `EpisodeDetailOverlay`,
/// trimmed to what a track actually has: album-art hero with title /
/// album / artist / duration, then the on-disk file's quality / size /
/// custom-formats banner (or a quiet "missing" line). Pushed from the
/// album view's track list; back pops to the album.
struct TrackDetailOverlay: View {
    let track: LidarrTrackDetail
    /// The joined `/trackfile` record — nil when the track has no file
    /// (or the file list hasn't loaded), which renders the missing state.
    let file: LidarrTrackFile?
    let albumTitle: String?
    let artistName: String?
    let posterURL: URL?
    var posterAPIKey: String? = nil
    let onClose: () -> Void

    @Environment(\.isDetachedWindow) private var isDetachedWindow
    @State private var enlargedPoster: URL?

    private var navTitle: String {
        String(format: String(localized: "detail.trackLld.label", bundle: .module),
               track.absoluteTrackNumber ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Self-drawn back header — the popover / detached window draw no
            // NavigationStack chevron (same pattern as every detail surface).
            HStack(spacing: 6) {
                FloatingBackButton(action: onClose)
                    .keyboardShortcut(.cancelAction)
                Text(navTitle)
                    .scaledFont(size: 15, weight: .semibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    hero
                    fileSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .posterLightbox(url: $enlargedPoster, apiKey: posterAPIKey, aspectRatio: 1)
        .conditionalNavTitle(navTitle, apply: !isDetachedWindow)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .windowToolbar)
        #endif
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(.smooth(duration: 0.22)) { enlargedPoster = posterURL }
            } label: {
                RemotePoster(
                    url: posterURL,
                    apiKey: posterAPIKey,
                    size: CGSize(width: 84, height: 84),
                    cornerRadius: Tokens.Radius.card,
                    fallbackSymbol: "music.note"
                )
            }
            .buttonStyle(.plain)
            .disabled(posterURL == nil)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title ?? "—")
                    .scaledFont(size: 15, weight: .semibold)
                    .lineLimit(3)
                if let albumTitle, !albumTitle.isEmpty {
                    Text(artistName.map { "\(albumTitle) · \($0)" } ?? albumTitle)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let dur = track.duration, dur > 0 {
                    Text(formatDuration(ms: dur))
                        .scaledFont(size: 11, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// On-disk file → the same quality / size / formats banner episodes use;
    /// no file → the row-text vocabulary ("Missing") in a quiet line.
    @ViewBuilder
    private var fileSection: some View {
        if let file {
            VStack(alignment: .leading, spacing: 6) {
                InLibraryBadge()
                ExistingFileBanner(
                    quality: file.quality?.quality?.name,
                    size: file.size,
                    customFormatScore: file.customFormatScore,
                    customFormats: (file.customFormats ?? []).map(\.name),
                    fileName: nil,
                    showMetadata: true
                )
            }
        } else if track.hasFile != true {
            Text("search.missing.button", bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
        }
    }
}
