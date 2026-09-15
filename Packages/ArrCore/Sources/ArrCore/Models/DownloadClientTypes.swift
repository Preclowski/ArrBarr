import Foundation

// MARK: - SABnzbd

nonisolated public struct SabQueueResponse: Decodable {
    let queue: SabQueue
}

nonisolated public struct SabQueue: Decodable {
    let paused: Bool
    let slots: [SabSlot]
}

nonisolated public struct SabSlot: Decodable {
    let nzo_id: String
    let filename: String
    let status: String
    let mb: String
    let mbleft: String
    let percentage: String
    let timeleft: String?
}

// MARK: - qBittorrent

nonisolated public struct QbitTorrent: Decodable {
    let hash: String
    let name: String
    let state: String
    let progress: Double
    let dlspeed: Int64
    let eta: Int64
    let size: Int64
}
