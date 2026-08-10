import SwiftUI

struct ProgressLine: View {
    let item: QueueItem
    var hideDownloadClient: Bool = false

    public var body: some View {
        // One row was cramming status + percentage + quality + time left +
        // size + client all on a single line, which wrapped "Downloading" to
        // two lines on narrow popovers. Split: status / progress / client on
        // top (the "what's happening" line), technical details (quality ·
        // time · size) below.
        VStack(alignment: .leading, spacing: 2) {
            statusRow
            // detailsRow now always renders when there's meta OR a
            // client to surface — the client lives there post-refactor.
            if hasDetails || (!hideDownloadClient && item.downloadClient != nil) {
                detailsRow
            }
        }
    }

    // Right gutter for both rows mirrors QueueRowView's pattern: score
    // on the status line, download client on the details line — see
    // `QueueItemPrimitives` for the shared atoms.
    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 4) {
            StatusIconLabel(status: item.status,
                            iconSize: 10,
                            labelSize: 11,
                            labelWeight: .semibold)
            Spacer(minLength: 6)
            ScoreLabel(score: item.customFormatScore,
                       baseline: item.existingCustomFormatScore, size: 11)
        }
    }

    @ViewBuilder
    private var detailsRow: some View {
        HStack(spacing: 4) {
            let segments: [String] = [
                item.quality.flatMap { $0.isEmpty ? nil : $0 },
                formattedTimeLeft,
                item.sizeTotal > 0 ? sizeText : nil,
            ].compactMap { $0 }
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                if idx > 0 { SeparatorDot() }
                Text(verbatim: segment)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if !hideDownloadClient, let client = item.downloadClient {
                DownloadClientLabel(name: client, size: 10)
            }
        }
    }

    /// `detailsRow` now always renders (it carries the download client
    /// even when no other meta exists), so the `if hasDetails` gate in
    /// the parent body has to broaden too. Kept the legacy helper for
    /// future readers — the body uses the broadened condition inline.

    private var hasDetails: Bool {
        (item.quality?.isEmpty == false) || formattedTimeLeft != nil || item.sizeTotal > 0
    }

    private var sizeText: String {
        let done = max(0, item.sizeTotal - item.sizeLeft)
        return "\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file))"
    }

    private var formattedTimeLeft: String? {
        TimeLeftFormatter.format(item.timeLeft)
    }
}
