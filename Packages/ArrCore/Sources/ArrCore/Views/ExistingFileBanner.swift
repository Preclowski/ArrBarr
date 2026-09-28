import SwiftUI
import MediaKit

/// Shared by the Library tooltip and the existing-file banner; unknown values fall back to the capitalized raw string.
enum ArrReleaseStatusLabel {
    static func text(_ raw: String?, locale: Locale) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let keys: [String: String] = [
            "tba": "library.release.tba",
            "announced": "library.release.announced",
            "incinemas": "library.release.inCinemas",
            "released": "library.release.released",
            "deleted": "library.release.deleted",
            "continuing": "library.release.continuing",
            "ended": "library.release.ended",
            "upcoming": "library.release.upcoming",
        ]
        if let key = keys[raw.lowercased()] {
            return AppLocalized.string(key, locale: locale)
        }
        return raw.capitalized
    }
}

struct ExistingFileBanner: View {
    let quality: String?
    let size: Int64?
    let customFormatScore: Int?
    let customFormats: [String]
    let fileName: String?
    var releaseGroup: String?
    var languages: String?

    init(quality: String?, size: Int64?, customFormatScore: Int?,
         customFormats: [String], fileName: String?,
         releaseGroup: String? = nil, languages: String? = nil) {
        self.quality = quality; self.size = size
        self.customFormatScore = customFormatScore
        self.customFormats = customFormats
        self.fileName = fileName
        self.releaseGroup = releaseGroup
        self.languages = languages
    }

    /// Lidarr sends only an absolute `path`, so the name falls back to its last component.
    init(file: ArrFile) {
        let languages = (file.languages ?? []).compactMap(\.name)
        self.init(
            quality: file.quality?.name,
            size: file.size,
            customFormatScore: file.customFormatScore,
            customFormats: (file.customFormats ?? []).map(\.name),
            fileName: file.relativePath ?? file.path.map { URL(fileURLWithPath: $0).lastPathComponent },
            releaseGroup: file.releaseGroup,
            languages: languages.isEmpty ? nil : languages.joined(separator: ", ")
        )
    }

    var body: some View {
        // Same labels and order as `UpgradeDiffTable`, so on-disk file and incoming release read alike.
        VStack(alignment: .leading, spacing: 5) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                if let q = quality, !q.isEmpty {
                    GridRow {
                        label("queue.quality.button")
                        value(q, weight: .semibold)
                    }
                }
                if let s = size, s > 0 {
                    GridRow {
                        label("queue.size.button")
                        value(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                    }
                }
                if let releaseGroup, !releaseGroup.isEmpty {
                    GridRow {
                        label("Release group")
                        value(releaseGroup)
                    }
                }
                if let languages, !languages.isEmpty {
                    GridRow {
                        label("Languages")
                        value(languages)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !customFormats.isEmpty || (customFormatScore ?? 0) != 0 {
                TooltipFlowLayout(spacing: 4) {
                    ForEach(customFormats, id: \.self) { cf in
                        TagChip(text: cf, color: .primary)
                    }
                    if let score = customFormatScore, score != 0 {
                        ScoreChip(score: score)
                    }
                }
            }
            if let name = fileName, !name.isEmpty {
                // Never truncated.
                Text(name)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private func value(_ text: String, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: weight)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .gridColumnAlignment(.leading)
    }
}
