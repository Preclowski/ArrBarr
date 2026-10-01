import SwiftUI

/// The title's clips under the cast. Thumbnails come straight from YouTube's image host for now.
struct TrailerRow: View {
    let reel: TrailerReel
    private var session: TrailerSession { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailSectionHeader("detail.trailers.label", count: reel.clips.count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(reel.clips) { clip in
                        TrailerTile(clip: clip, isPlaying: session.key == clip.key && session.isShowing(reel)) {
                            withAnimation(.smooth(duration: 0.22)) { session.present(reel, startingAt: clip) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct TrailerTile: View {
    let clip: TrailerClip
    let isPlaying: Bool
    let action: () -> Void
    @State private var hovering = false

    private static let thumbnail = CGSize(width: 136, height: 76.5)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                RemotePoster(url: clip.thumbnailURL, apiKey: nil, tier: .icon,
                             size: Self.thumbnail, cornerRadius: Tokens.Radius.chip,
                             fallbackSymbol: "play.rectangle")
                    .overlay {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.fill")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(hovering ? 0.65 : 0.45), in: Circle())
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                            .strokeBorder(Color.accentColor, lineWidth: isPlaying ? 2 : 0)
                    }
                Group {
                    if let name = clip.name, !name.isEmpty {
                        Text(verbatim: name)
                    } else {
                        Text("detail.trailer.button", bundle: .module)
                    }
                }
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            }
            .frame(width: Self.thumbnail.width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(.smooth(duration: 0.15)) { hovering = over } }
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
        #if os(macOS)
        .pointerStyle(.link)
        #endif
    }
}
