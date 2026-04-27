import Foundation
import AppKit
import CryptoKit
import os

actor ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, NSImage>()
    private let cacheDir: URL
    private let session: URLSession
    private let logger = Logger(subsystem: "com.preclowski.ArrBarr", category: "ImageCache")

    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private var negativeCache: [String: Date] = [:]
    private static let negativeTTL: TimeInterval = 60 * 60 // 1 hour
    private static let memoryCostCap = 50 * 1024 * 1024     // 50 MB

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundleId = Bundle.main.bundleIdentifier ?? "com.preclowski.ArrBarr"
        cacheDir = caches.appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("posters", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg)

        memory.totalCostLimit = Self.memoryCostCap
    }

    func image(for url: URL, apiKey: String? = nil) async -> NSImage? {
        let key = Self.cacheKey(for: url)

        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let until = negativeCache[key], until > Date() { return nil }

        if let task = inflight[key] {
            return await task.value
        }

        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadOrFetch(url: url, key: key, apiKey: apiKey)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    private func loadOrFetch(url: URL, key: String, apiKey: String?) async -> NSImage? {
        let fileURL = cacheDir.appendingPathComponent(key)
        if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
            store(image: image, data: data, key: key)
            touch(fileURL)
            return image
        }

        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                negativeCache[key] = Date().addingTimeInterval(Self.negativeTTL)
                logger.debug("poster \(http.statusCode, privacy: .public) for \(url.absoluteString, privacy: .public)")
                return nil
            }
            guard let image = NSImage(data: data) else {
                negativeCache[key] = Date().addingTimeInterval(Self.negativeTTL)
                return nil
            }
            store(image: image, data: data, key: key)
            try? data.write(to: fileURL, options: .atomic)
            return image
        } catch {
            negativeCache[key] = Date().addingTimeInterval(Self.negativeTTL)
            logger.debug("poster fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func store(image: NSImage, data: Data, key: String) {
        memory.setObject(image, forKey: key as NSString, cost: data.count)
    }

    private func touch(_ fileURL: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
    }

    func purgeOlderThan(_ days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var purged = 0
        for entry in entries {
            let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if mtime < cutoff {
                try? fm.removeItem(at: entry)
                purged += 1
            }
        }
        if purged > 0 { logger.info("purged \(purged, privacy: .public) old poster files") }
    }

    private static func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
