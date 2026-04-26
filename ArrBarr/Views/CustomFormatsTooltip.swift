import SwiftUI

// Plik celowo zostawiony jako miejsce na #Preview / SwiftUI mocki w rozwoju.
// Tooltip z custom formatami trafił finalnie do .help() w QueueRowView (natywny system tooltip).
// Jeśli chcesz bogatszy tooltip z kolorowymi tagami — przywróć tu FlowLayout + popover trigger.

#if DEBUG
private let _previewItem = QueueItem(
    id: "sonarr-1",
    source: .sonarr,
    arrQueueId: 1,
    downloadId: "abc123",
    downloadProtocol: .torrent,
    downloadClient: "qBittorrent",
    title: "Severance",
    subtitle: "S02E03 · Who Is Alive?",
    status: .downloading,
    progress: 0.42,
    sizeTotal: 4_500_000_000,
    sizeLeft: 2_600_000_000,
    timeLeft: "00:23:45",
    customFormats: ["x265", "WEB", "Multi-Audio"],
    customFormatScore: 350,
    quality: "WEBDL-1080p"
)
#endif
