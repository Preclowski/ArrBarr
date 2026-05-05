import Foundation

// MARK: - SABnzbd

public struct SabQueueResponse: Decodable {
    let queue: SabQueue
}

public struct SabQueue: Decodable {
    let paused: Bool
    let slots: [SabSlot]
}

public struct SabSlot: Decodable {
    let nzo_id: String
    let filename: String
    let status: String
    let mb: String
    let mbleft: String
    let percentage: String
    let timeleft: String?
}

// MARK: - qBittorrent

public struct QbitTorrent: Decodable {
    let hash: String
    let name: String
    let state: String
    let progress: Double
    let dlspeed: Int64
    let eta: Int64
    let size: Int64
}
