import SwiftUI
import MediaKit

/// Audio counterpart of `EpisodeDetailOverlay`, pushed from the album's track list.
struct TrackDetailOverlay: View {
    let track: ArrTrack
    /// Nil (no file, or not loaded yet) renders the missing state.
    let file: ArrFile?
    let albumTitle: String?
    /// A drill-in link when `onOpenArtist` is wired.
    let artist: ArrArtist?
    let posterURL: URL?
    var posterAPIKey: String? = nil
    var onOpenArtist: ((ArrArtist) -> Void)? = nil
    let onClose: () -> Void

    @Environment(\.isDetachedWindow) private var isDetachedWindow
    @State private var enlargedPoster: URL?

    private var navTitle: String { track.title ?? "—" }

    private var trackNumberLabel: String {
        String(format: String(localized: "detail.trackLld.label", bundle: .module),
               track.absoluteTrackNumber ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // The popover and detached window draw no NavigationStack chevron.
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
                    size: CGSize(width: 110, height: 110),
                    cornerRadius: Tokens.Radius.card,
                    fallbackSymbol: "music.note"
                )
            }
            .buttonStyle(.plain)
            .disabled(posterURL == nil)
            .posterMarks(library: LibraryMark(downloaded: file != nil || track.hasFile == true),
                         cornerRadius: Tokens.Radius.card)

            VStack(alignment: .leading, spacing: 4) {
                if let artist, let artistName = artist.artistName {
                    if let onOpenArtist {
                        Button { onOpenArtist(artist) } label: {
                            HStack(spacing: 3) {
                                Text(artistName)
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                LinkChevron()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Text("detail.showArtist.button", bundle: .module))
                    } else {
                        Text(artistName)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if let albumTitle, !albumTitle.isEmpty {
                    Text(albumTitle)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(trackNumberLabel)
                    if let dur = track.duration, dur > 0 {
                        SeparatorDot()
                        Text(formatDuration(ms: dur))
                            .monospacedDigit()
                    }
                }
                .scaledFont(size: 11)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var fileSection: some View {
        if let file {
            VStack(alignment: .leading, spacing: 6) {
                DetailSectionHeader("Existing file")
                ExistingFileBanner(file: file)
            }
        } else if track.hasFile != true {
            Text("search.missing.button", bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
        }
    }
}
