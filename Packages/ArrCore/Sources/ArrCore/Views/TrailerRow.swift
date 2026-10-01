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

extension TrailerReel {
    /// Warms the first tiles' stills before the row shows, so it lands with its pictures instead of empty
    /// frames. Waits at most `within`; a slow image host keeps filling the cache in the background.
    func prefetchThumbnails(limit: Int = 6, within: Duration = .milliseconds(1500)) async {
        let urls = clips.prefix(limit).compactMap(\.thumbnailURL)
        let warm = Task {
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask { _ = await PosterStore.shared.image(for: url, tier: .icon) }
                }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await warm.value }
            group.addTask { try? await Task.sleep(for: within) }
            await group.next()
            group.cancelAll()
        }
    }
}

private struct TrailerTile: View {
    let clip: TrailerClip
    let isPlaying: Bool
    let action: () -> Void
    @State private var hovering = false

    private static let thumbnail = TrailerClip.thumbnailSize

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
        .accessibilityLabel(clip.name.map { Text(verbatim: $0) } ?? Text("detail.trailer.button", bundle: .module))
        .onHover { over in withAnimation(.smooth(duration: 0.15)) { hovering = over } }
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
        #if os(macOS)
        .pointerStyle(.link)
        #endif
    }
}
