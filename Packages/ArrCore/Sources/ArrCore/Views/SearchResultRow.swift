import SwiftUI

public struct SearchResultRow: View {
    let result: SearchResult
    let onTap: () -> Void

    @EnvironmentObject var configStore: ConfigStore
    @State private var isHovering = false

    private var shouldBlur: Bool {
        configStore.shouldBlurPoster(for: result.source)
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                PosterBlurContainer(blurred: shouldBlur, cornerRadius: 3) {
                    RemotePoster(url: result.posterURL, apiKey: nil, size: CGSize(width: 26, height: 38), cornerRadius: 3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleWithYear)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    metadataLine
                        .font(.system(size: 10))
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hover tint mirroring QueueRowView / UpcomingRowView — signals
        // that the row is interactive (tap opens the SearchAddPanel).
        #if os(macOS)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, 6)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        #endif
    }

    /// "Title (1994)" — same idea as MediaHeaderCard. The year is just a
    /// year, so it joins the title rather than burning a metadata segment.
    private var titleWithYear: String {
        if let year = result.year {
            return "\(result.title) (\(year))"
        }
        return result.title
    }

    /// Second-line metadata. Arr's lookup endpoint hands us all of these in
    /// the same response that fetched the row, so showing them costs zero
    /// extra requests: subtitle (Sonarr "X seasons" / Lidarr disambiguation)
    /// → IMDb → RT → Metacritic → TMDB → runtime → certification.
    /// Filter to what's populated and join with dots.
    @ViewBuilder
    private var metadataLine: some View {
        let segments: [String] = [
            result.subtitle.flatMap { $0.isEmpty ? nil : $0 },
            result.imdb.map { String(format: "IMDb %.1f", $0) },
            result.rottenTomatoes.map { "RT \(Int($0))%" },
            result.metacritic.map { "MC \(Int($0))" },
            result.imdb == nil ? result.rating.map { String(format: "★%.1f", $0) } : nil,
            result.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
            result.certification.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }

        if segments.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    if idx > 0 {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(seg).foregroundStyle(.secondary)
                }
            }
        }
    }
}
