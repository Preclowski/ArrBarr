import Foundation

// MARK: - SABnzbd JSON

struct SabQueueResponse: Decodable {
    let queue: SabQueue
}

struct SabQueue: Decodable {
    let paused: Bool
    let slots: [SabSlot]
}

struct SabSlot: Decodable {
    let nzo_id: String
    let filename: String
    let status: String       // "Downloading" / "Paused" / "Queued" / itp.
    let mb: String           // total MB jako string!
    let mbleft: String
    let percentage: String   // "23"
    let timeleft: String?    // "0:23:45"
}

// MARK: - qBittorrent JSON

struct QbitTorrent: Decodable {
    let hash: String
    let name: String
    let state: String        // "downloading", "pausedDL", "stalledDL", "queuedDL", "uploading", ...
    let progress: Double     // 0.0...1.0
    let dlspeed: Int64
    let eta: Int64           // sekundy; 8640000 = "infinite"
    let size: Int64
}
