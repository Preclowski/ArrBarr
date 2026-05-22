import SwiftUI

public struct SearchResultRow: View {
    let result: SearchResult
    let onTap: () -> Void

    @EnvironmentObject var configStore: ConfigStore

    private var shouldBlur: Bool {
        result.source == .whisparr && configStore.blurWhisparrPosters
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                PosterBlurContainer(blurred: shouldBlur) {
                    RemotePoster(url: result.posterURL, apiKey: nil, size: CGSize(width: 26, height: 38), cornerRadius: 3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let year = result.year {
                            Text(verbatim: "\(year)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let sub = result.subtitle {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(sub)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let r = result.rating {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(String(format: "★%.1f", r))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
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
    }
}
