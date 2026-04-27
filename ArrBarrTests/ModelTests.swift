import Testing
import Foundation
@testable import ArrBarr

@Suite("ServiceConfig")
struct ServiceConfigTests {
    @Test("Valid URL with scheme and host is configured")
    func validConfig() {
        let config = ServiceConfig(enabled: true, baseURL: "http://localhost:7878", apiKey: "abc", username: "", password: "")
        #expect(config.isConfigured)
    }

    @Test("Disabled config is not configured regardless of URL")
    func disabled() {
        let config = ServiceConfig(enabled: false, baseURL: "http://localhost:7878", apiKey: "abc", username: "", password: "")
        #expect(!config.isConfigured)
    }

    @Test("Empty URL is not configured")
    func emptyURL() {
        let config = ServiceConfig(enabled: true, baseURL: "", apiKey: "", username: "", password: "")
        #expect(!config.isConfigured)
    }

    @Test("URL without scheme is not configured")
    func noScheme() {
        let config = ServiceConfig(enabled: true, baseURL: "localhost:7878", apiKey: "", username: "", password: "")
        #expect(!config.isConfigured)
    }

    @Test("HTTPS URL is configured")
    func httpsURL() {
        let config = ServiceConfig(enabled: true, baseURL: "https://radarr.example.com", apiKey: "key", username: "", password: "")
        #expect(config.isConfigured)
    }

    @Test("Non-HTTP schemes are rejected")
    func rejectsNonHTTP() {
        for scheme in ["file:///etc/passwd", "ftp://server", "javascript:alert(1)"] {
            let config = ServiceConfig(enabled: true, baseURL: scheme, apiKey: "", username: "", password: "")
            #expect(!config.isConfigured, "Should reject: \(scheme)")
        }
    }

    @Test("Static empty config is not configured")
    func emptyStatic() {
        #expect(!ServiceConfig.empty.isConfigured)
    }

    @Test("Empty config has enabled set to false")
    func emptyDefaults() {
        #expect(!ServiceConfig.empty.enabled)
        #expect(ServiceConfig.empty.baseURL.isEmpty)
        #expect(ServiceConfig.empty.apiKey.isEmpty)
    }
}

@Suite("ServiceKind")
struct ServiceKindTests {
    @Test("All cases have correct display names")
    func displayNames() {
        #expect(ServiceKind.radarr.displayName == "Radarr")
        #expect(ServiceKind.sonarr.displayName == "Sonarr")
        #expect(ServiceKind.sabnzbd.displayName == "SABnzbd")
        #expect(ServiceKind.qbittorrent.displayName == "qBittorrent")
        #expect(ServiceKind.nzbget.displayName == "NZBGet")
        #expect(ServiceKind.transmission.displayName == "Transmission")
        #expect(ServiceKind.rtorrent.displayName == "rTorrent")
        #expect(ServiceKind.deluge.displayName == "Deluge")
    }

    @Test("API key required for Arr services and SABnzbd only")
    func apiKeyRequirements() {
        #expect(ServiceKind.radarr.requiresApiKey)
        #expect(ServiceKind.sonarr.requiresApiKey)
        #expect(ServiceKind.sabnzbd.requiresApiKey)
        #expect(!ServiceKind.qbittorrent.requiresApiKey)
        #expect(!ServiceKind.nzbget.requiresApiKey)
        #expect(!ServiceKind.transmission.requiresApiKey)
        #expect(!ServiceKind.rtorrent.requiresApiKey)
        #expect(!ServiceKind.deluge.requiresApiKey)
    }

    @Test("Download clients require login credentials")
    func loginRequirements() {
        #expect(ServiceKind.qbittorrent.requiresLogin)
        #expect(ServiceKind.nzbget.requiresLogin)
        #expect(ServiceKind.transmission.requiresLogin)
        #expect(ServiceKind.rtorrent.requiresLogin)
        #expect(ServiceKind.deluge.requiresLogin)
        #expect(!ServiceKind.radarr.requiresLogin)
        #expect(!ServiceKind.sonarr.requiresLogin)
        #expect(!ServiceKind.sabnzbd.requiresLogin)
    }

    @Test("CaseIterable covers all nine services")
    func allCases() {
        #expect(ServiceKind.allCases.count == 9)
    }
}

@Suite("UpcomingItem")
struct UpcomingItemTests {
    @Test("Today's date formats as 'Today'")
    func today() {
        let item = UpcomingItem(
            id: "test-1", source: .radarr, title: "Test",
            subtitle: nil, airDate: Date(), releaseType: "Digital",
            hasFile: false, overview: nil
        )
        #expect(item.airDateFormatted == "Today")
    }

    @Test("Tomorrow's date formats as 'Tomorrow'")
    func tomorrow() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let item = UpcomingItem(
            id: "test-2", source: .sonarr, title: "Test",
            subtitle: "S01E01", airDate: tomorrow, releaseType: "Airing",
            hasFile: false, overview: nil
        )
        #expect(item.airDateFormatted == "Tomorrow")
    }

    @Test("Future date uses medium date format")
    func futureDate() {
        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: Date())!
        let item = UpcomingItem(
            id: "test-3", source: .radarr, title: "Test",
            subtitle: nil, airDate: nextWeek, releaseType: "In Cinemas",
            hasFile: false, overview: nil
        )
        let formatted = item.airDateFormatted
        #expect(formatted != "Today")
        #expect(formatted != "Tomorrow")
        #expect(!formatted.isEmpty)
    }
}

@Suite("QueueItem")
struct QueueItemTests {
    static func make(status: QueueItem.Status = .downloading, progress: Double = 0.5) -> QueueItem {
        QueueItem(
            id: "radarr-1", source: .radarr, arrQueueId: 1,
            downloadId: "abc", downloadProtocol: .usenet,
            downloadClient: "SABnzbd", title: "Test Movie (2024)",
            subtitle: nil, status: status, progress: progress,
            sizeTotal: 1_000_000, sizeLeft: 500_000,
            timeLeft: "00:30:00", customFormats: ["IMAX"],
            customFormatScore: 100, quality: "Bluray-1080p",
            isUpgrade: false, contentSlug: "test-movie-2024"
        )
    }

    @Test("isPaused is true only when status is paused")
    func isPaused() {
        #expect(!Self.make(status: .downloading).isPaused)
        #expect(Self.make(status: .paused).isPaused)
        #expect(!Self.make(status: .queued).isPaused)
    }

    @Test("isCompleted is true only when status is completed")
    func isCompleted() {
        #expect(!Self.make(status: .downloading).isCompleted)
        #expect(Self.make(status: .completed).isCompleted)
        #expect(!Self.make(status: .paused).isCompleted)
    }

    @Test("All status values have display names")
    func statusDisplayNames() {
        let expected: [QueueItem.Status: String] = [
            .downloading: "Downloading",
            .paused: "Paused",
            .queued: "Queued",
            .completed: "Completed",
            .warning: "Warning",
            .failed: "Failed",
            .unknown: "Unknown",
        ]
        for (status, name) in expected {
            #expect(status.displayName == name)
        }
    }

    @Test("Equatable conformance")
    func equatable() {
        let a = Self.make()
        let b = Self.make()
        #expect(a == b)
    }
}
