import Testing
import ArrCore
import Foundation
@testable import ArrMCPServer

// MARK: - Builders

private func download(
    _ title: String, poster: URL? = nil,
    status: QueueItem.Status = .downloading, progress: Double = 0.42
) -> StartPageSnapshot.Download {
    .init(title: title, subtitle: "S01E01", source: .radarr, status: status,
          progress: progress, bytesLeft: 1_288_000_000, sizeTotal: 4_500_000_000,
          timeLeft: "00:05:00", quality: "Bluray-2160p", downloadProtocol: .usenet,
          indexer: "DemoUsenet", downloadClient: "NZBGet",
          releaseName: "Tears.of.Steel.2012.2160p.BluRay.x265.HDR10.DV.Atmos-DEMO",
          customFormats: ["Atmos", "DV", "HDR10+", "TrueHD", "x265"], customFormatScore: 1720,
          isUpgrade: true, existingQuality: "Bluray-1080p", existingSize: 8_400_000_000,
          existingCustomFormats: ["DTS-HD MA 5.1", "x264"], existingCustomFormatScore: 350,
          existingFileName: "Tears.of.Steel.2012.1080p.BluRay.x264-OLD.mkv", posterURL: poster)
}

private func upcoming(_ title: String, poster: URL? = nil) -> StartPageSnapshot.Upcoming {
    .init(title: title, subtitle: "S02E01", source: .sonarr,
          airDate: Date(timeIntervalSince1970: 1_800_000_000),
          overview: "A gripping synopsis.", imdb: 7.8, runtime: 42, posterURL: poster)
}

private func snapshot(
    downloads: [StartPageSnapshot.Download] = [],
    upcoming: [StartPageSnapshot.Upcoming] = [],
    upcomingTotal: Int? = nil,
    services: [StartPageSnapshot.Service] = [],
    offline: Bool = false, errors: [String] = []
) -> StartPageSnapshot {
    let stats = StartPageSnapshot.Stats(
        downloading: downloads.filter { $0.status == .downloading }.count,
        queued: 0, paused: 0, importing: 0, total: downloads.count,
        bytesLeft: downloads.reduce(0) { $0 + $1.bytesLeft })
    return .init(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), offline: offline,
                 errors: errors, services: services, stats: stats, downloads: downloads,
                 upcoming: upcoming, upcomingTotal: upcomingTotal ?? upcoming.count)
}

private func get(_ path: String, port: Int) async throws -> (Int, Data, [AnyHashable: Any]) {
    let (data, response) = try await URLSession.shared.data(
        from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    let http = response as! HTTPURLResponse
    return (http.statusCode, data, http.allHeaderFields)
}

private let noPosters: @Sendable (URL) async -> Data? = { _ in nil }

// MARK: - Page + JSON

@Test func startPage_servesHtmlAndJsonOverSocket() async throws {
    let port = 38530
    let snap = snapshot(
        downloads: [download("The Matrix")],
        upcoming: [upcoming("Severance")])

    let controller = StartPageController()
    await controller.restart(with: .init(port: port, snapshotProvider: { snap },
                                         posterProvider: noPosters))
    defer { Task { await controller.stop() } }

    let (status, data, headers) = try await get("/", port: port)
    let html = String(decoding: data, as: UTF8.self)
    #expect(status == 200)
    #expect((headers["Content-Type"] as? String)?.contains("text/html") == true)
    #expect(html.contains("<title>ArrBarr</title>"))
    #expect(html.contains("The Matrix"))
    #expect(html.contains("Radarr"))
    #expect(html.contains("Downloading"))
    #expect(html.contains("Coming up"))
    #expect(html.contains("Severance"))

    let (jsonStatus, jsonData, jsonHeaders) = try await get("/status.json", port: port)
    #expect(jsonStatus == 200)
    #expect((jsonHeaders["Content-Type"] as? String)?.contains("application/json") == true)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(StartPageSnapshot.self, from: jsonData)
    #expect(decoded.downloads.first?.title == "The Matrix")
    #expect(decoded.downloads.first?.bytesLeft == 1_288_000_000)  // raw, not pre-formatted
    #expect(decoded.upcoming.first?.title == "Severance")

    await controller.stop()
}

@Test func startPage_returns404ForUnknownPath() async throws {
    let port = 38531
    let controller = StartPageController()
    await controller.restart(with: .init(port: port, snapshotProvider: { snapshot() },
                                         posterProvider: noPosters))
    defer { Task { await controller.stop() } }

    let (status, _, _) = try await get("/secrets", port: port)
    #expect(status == 404)
    await controller.stop()
}

// MARK: - Poster proxy

@Test func startPage_proxiesPosterForOnPageURL() async throws {
    let port = 38532
    let posterURL = URL(string: "http://arr.local/MediaCover/1/poster.jpg")!
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 24))
    let snap = snapshot(downloads: [download("The Matrix", poster: posterURL)])

    let controller = StartPageController()
    await controller.restart(with: .init(port: port, snapshotProvider: { snap },
        posterProvider: { url in url == posterURL ? png : nil }))
    defer { Task { await controller.stop() } }

    // Page must reference the proxied poster, not the raw arr URL.
    let (_, pageData, _) = try await get("/", port: port)
    let html = String(decoding: pageData, as: UTF8.self)
    #expect(html.contains("/poster?u="))
    #expect(!html.contains("arr.local"))

    // The token round-trips and the route streams the image with a sniffed type.
    let token = StartPagePosterToken.encode(posterURL)
    let (status, data, headers) = try await get("/poster?u=\(token)", port: port)
    #expect(status == 200)
    #expect((headers["Content-Type"] as? String) == "image/png")
    #expect(data == png)

    // An off-page URL (provider returns nil → SSRF guard) 404s.
    let evil = StartPagePosterToken.encode(URL(string: "http://169.254.169.254/latest/meta-data")!)
    let (evilStatus, _, _) = try await get("/poster?u=\(evil)", port: port)
    #expect(evilStatus == 404)

    await controller.stop()
}

@Test func posterToken_roundTrips() {
    let url = URL(string: "https://image.tmdb.org/t/p/w500/abc+def/poster.jpg?x=1")!
    #expect(StartPagePosterToken.decode(StartPagePosterToken.encode(url)) == url)
}

// MARK: - Renderer

@Test func renderer_escapesUserContent() {
    let html = StartPageRenderer.html(snapshot(downloads: [download("<script>alert(1)</script>")]))
    #expect(!html.contains("<script>alert(1)</script>"))
    #expect(html.contains("&lt;script&gt;"))
}

@Test func renderer_showsIdleAndHidesEmptyUpcoming() {
    let html = StartPageRenderer.html(snapshot())
    #expect(html.contains("Nothing downloading — all caught up."))
    #expect(!html.contains("Coming up"))   // section hidden when there's nothing
}

@Test func renderer_showsOfflinePill() {
    let html = StartPageRenderer.html(snapshot(offline: true))
    #expect(html.contains("Offline"))
}

@Test func renderer_showsServerHealth() {
    let services: [StartPageSnapshot.Service] = [
        .init(name: "Sonarr", health: .ok, detail: "4.0.0", warnings: 0, url: "http://nas.local:8989", iconName: nil),
        .init(name: "qBittorrent", health: .down, detail: "Connection refused", warnings: 0, url: nil, iconName: nil),
        .init(name: "Radarr", health: .ok, detail: nil, warnings: 3, url: "http://nas.local:7878", iconName: nil),
    ]
    let html = StartPageRenderer.html(snapshot(services: services))
    #expect(html.contains("Servers"))
    #expect(html.contains("Sonarr"))
    #expect(html.contains("qBittorrent"))
    #expect(html.contains(#"dot down"#))          // the failing server's red dot
    #expect(html.contains(#"class="wct">3"#))     // Radarr's warning count
    // A downed server drives the top pill.
    #expect(html.contains("1 server down"))
    // Configured services link to their web UI; unconfigured ones don't.
    #expect(html.contains(#"href="http://nas.local:8989""#))
    #expect(html.contains(#"<a class="srv glass" href="http://nas.local:7878""#))
}

@Test func renderer_serverChip_rejectsUnsafeUrl() {
    // A stored config value that isn't http/https must never become an href.
    let services: [StartPageSnapshot.Service] = [
        .init(name: "Evil", health: .ok, detail: nil, warnings: 0, url: "javascript:alert(1)", iconName: nil),
    ]
    let html = StartPageRenderer.html(snapshot(services: services))
    #expect(!html.contains("javascript:"))
    #expect(!html.contains("<a class=\"srv"))    // rendered as a plain div, not a link
}

@Test func renderer_hoverPopoverCarriesDetails() {
    let d = download("The Matrix")
    let u = upcoming("Severance")
    let html = StartPageRenderer.html(snapshot(downloads: [d], upcoming: [u]))
    // Hover hosts + inert templates the page script clones.
    #expect(html.contains("data-pop"))
    #expect(html.contains(#"<template class="pop">"#))
    // Download grab card: badges, quality upgrade, score, format diff, release, indexer.
    #expect(html.contains("Upgrade"))                    // upgrade badge
    #expect(html.contains("NZBGet"))                     // client badge
    #expect(html.contains("Bluray-2160p"))               // new quality
    #expect(html.contains("Bluray-1080p"))               // replaced quality
    #expect(html.contains("+1720"))                      // new custom-format score
    #expect(html.contains(#"cf add">+Atmos"#))           // added format pill (green)
    #expect(html.contains(#"cf rem">−"#))                // removed format pill (red)
    #expect(html.contains("Tears.of.Steel.2012.2160p"))  // release name
    #expect(html.contains("DemoUsenet"))                 // indexer
    // Upcoming detail: rating, runtime, overview.
    #expect(html.contains("★ 7.8"))
    #expect(html.contains("42 min"))
    #expect(html.contains("A gripping synopsis."))
}

@Test func renderer_showsMoreUpcomingTile() {
    let up = (0..<5).map { upcoming("Show \($0)") }
    let html = StartPageRenderer.html(snapshot(upcoming: up, upcomingTotal: 9))
    #expect(html.contains("+4"))      // 9 total - 5 shown
    #expect(html.contains("more"))
}

@Test func renderer_formatsBytesInEnglish() {
    // 1,288,000,000 bytes → "1.29 GB" with a period, regardless of OS locale.
    let html = StartPageRenderer.html(snapshot(downloads: [download("x")]))
    #expect(html.contains("1.29 GB"))
}

// MARK: - Controller

@Test func controller_rejectsInvalidPort() async throws {
    actor Box { var failed = false; func markFailed() { failed = true } }
    let box = Box()
    let controller = StartPageController()
    await controller.setStatusHandler { status in
        if case .failed = status { Task { await box.markFailed() } }
    }
    await controller.restart(with: .init(port: 0, snapshotProvider: { snapshot() },
                                         posterProvider: noPosters))
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(await box.failed)
    await controller.stop()
}
