import Testing
import Foundation
@testable import ArrCore

/// Grouping policy of `NotificationCoalescer`.
///
/// The class posts straight to `UNUserNotificationCenter`, so these drive it
/// through its `deliver` seam and assert on what *would* have been banner-ed.
///
/// Time is virtual, via the `CoalescerScheduler` seam. Real run-loop timers were
/// tried first and do fire inside a SwiftPM test process — but "fires eventually"
/// isn't what these tests assert. Grouping is a statement about ordering: the
/// second episode has to land *before* the first one's deadline for the window to
/// slide at all. On a loaded machine a `Task.sleep(0.2)` can overshoot a 0.3 s
/// deadline, the setup itself comes apart, and the test fails for reasons that
/// have nothing to do with the code under test. A virtual clock makes the
/// ordering exact, so the assertions are about policy and nothing else.
///
/// Timings are the real shipping constants (8 s burst window, 5 s series hold,
/// 60 s cap) — virtual time is free, so there's no reason to test a scaled-down
/// stand-in for the policy that actually ships. All advances are whole seconds:
/// `Date` arithmetic on integers is exact, so a deadline that lands on the
/// instant we advance to fires rather than missing by a float ulp.
@MainActor
@Suite("NotificationCoalescer grouping")
struct NotificationCoalescerTests {

    // MARK: - Harness

    /// Virtual clock: nothing fires until a test says so, and then it fires
    /// exactly when the policy says it should.
    @MainActor
    final class VirtualClock: CoalescerScheduler {
        private struct Entry {
            let id: Int
            let fireAt: Date
            let body: @MainActor () -> Void
        }

        private var entries: [Entry] = []
        private var nextID = 0
        private(set) var now = Date(timeIntervalSinceReferenceDate: 0)

        func schedule(
            after delay: TimeInterval,
            _ body: @escaping @MainActor @Sendable () -> Void
        ) -> ScheduledTimer {
            nextID += 1
            let id = nextID
            entries.append(Entry(id: id, fireAt: now.addingTimeInterval(delay), body: body))
            return ScheduledTimer { [weak self] in
                self?.entries.removeAll { $0.id == id }
            }
        }

        /// Move virtual time forward, firing everything that comes due.
        ///
        /// Timers fire in deadline order with `now` set to their own deadline —
        /// not to the end of the jump — so a callback that reschedules (which is
        /// exactly what the sliding window does) computes its next deadline from
        /// the instant it actually ran. Ties break by scheduling order.
        func advance(by interval: TimeInterval) {
            let target = now.addingTimeInterval(interval)
            while let next = entries
                .filter({ $0.fireAt <= target })
                .min(by: { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) })
            {
                entries.removeAll { $0.id == next.id }
                now = next.fireAt
                next.body()
            }
            now = target
        }
    }

    @MainActor
    final class DeliveryRecorder {
        struct Call {
            let source: QueueItem.Source
            let items: [QueueItem]
        }
        private(set) var calls: [Call] = []
        func record(_ source: QueueItem.Source, _ items: [QueueItem]) {
            calls.append(Call(source: source, items: items))
        }
        func calls(for source: QueueItem.Source) -> [Call] {
            calls.filter { $0.source == source }
        }
    }

    /// Isolated `ConfigStore` — the seam means it's never actually read (nothing
    /// reaches `post`), but the initializer requires one.
    private static func makeConfigStore() -> ConfigStore {
        let suiteName = "test.coalescer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ConfigStore(defaults: defaults)
    }

    /// Defaults mirror the production policy.
    private static func makeCoalescer(
        clock: VirtualClock,
        burstWindow: TimeInterval = 8,
        delay: TimeInterval = 5,
        cap: TimeInterval = 60,
        recorder: DeliveryRecorder
    ) -> NotificationCoalescer {
        NotificationCoalescer(
            configStore: makeConfigStore(),
            burstWindow: burstWindow,
            seriesGroupingDelay: delay,
            seriesGroupingCap: cap,
            scheduler: clock,
            deliver: { source, items in recorder.record(source, items) }
        )
    }

    private static func grab(_ source: QueueItem.Source, _ title: String) -> QueueItem {
        QueueItem(
            id: "\(source.rawValue).\(title)",
            source: source, arrQueueId: 1,
            downloadId: nil, downloadProtocol: .torrent,
            downloadClient: "qBittorrent",
            title: title, subtitle: nil,
            status: .downloading, progress: 0,
            sizeTotal: 1_000, sizeLeft: 1_000, timeLeft: nil,
            customFormats: [], customFormatScore: 0,
            quality: "HDTV-720p", isUpgrade: false,
            contentSlug: nil
        )
    }

    // MARK: - Series (held + grouped)

    @Test("A lone series grab is held, then delivered once")
    func loneSeriesGrabIsHeldThenDelivered() {
        let clock = VirtualClock()
        let rec = DeliveryRecorder()
        let sut = Self.makeCoalescer(clock: clock, recorder: rec)

        sut.enqueue(Self.grab(.sonarr, "Ep1"))
        #expect(rec.calls.isEmpty, "a series grab must not fire immediately")

        clock.advance(by: 4)
        #expect(rec.calls.isEmpty, "it must stay held for the whole 5 s window")

        clock.advance(by: 2)
        #expect(rec.calls.count == 1)
        #expect(rec.calls.first?.source == .sonarr)
        #expect(rec.calls.first?.items.count == 1)
    }

    @Test("A second episode slides the window and joins the same group")
    func secondEpisodeSlidesTheWindow() {
        let clock = VirtualClock()
        let rec = DeliveryRecorder()
        let sut = Self.makeCoalescer(clock: clock, recorder: rec)

        sut.enqueue(Self.grab(.sonarr, "Ep1"))   // a fixed window would fire at t=5
        clock.advance(by: 3)
        sut.enqueue(Self.grab(.sonarr, "Ep2"))   // slides delivery out to t=8

        // t=6: past the ORIGINAL deadline. A fixed window would already have
        // delivered here — a sliding one has not. This is the discriminator.
        clock.advance(by: 3)
        #expect(rec.calls.isEmpty, "window did not slide — it delivered at the first deadline")

        clock.advance(by: 3)                      // t=9, past the slid deadline
        #expect(rec.calls.count == 1, "both episodes must arrive as ONE group")
        #expect(rec.calls.first?.items.count == 2)
    }

    @Test("Episodes arriving forever still deliver once the cap is reached")
    func capForcesDeliveryDespiteContinuousSliding() {
        let clock = VirtualClock()
        let rec = DeliveryRecorder()
        let sut = Self.makeCoalescer(clock: clock, recorder: rec)

        // Grabs arrive every 4 s — faster than the 5 s window — so a purely
        // sliding window would postpone delivery indefinitely. The cap must win.
        for i in 0..<14 {                        // grabs at t = 0, 4, … 52
            sut.enqueue(Self.grab(.sonarr, "Ep\(i)"))
            clock.advance(by: 4)
        }
        #expect(rec.calls.isEmpty, "before the cap, sliding should still be holding everything")

        sut.enqueue(Self.grab(.sonarr, "Ep14"))  // t=56 — grabs are still arriving
        clock.advance(by: 4)                     // t=60: the cap

        #expect(rec.calls.count == 1, "the cap must force delivery while grabs are still arriving")
        #expect(rec.calls.first?.items.count == 15, "the whole held group goes out together")
    }

    // MARK: - Movies / music (leading edge)

    @Test("A movie grab is instant, and its tail becomes exactly one batch")
    func movieGrabIsInstantThenTailBatches() {
        let clock = VirtualClock()
        let rec = DeliveryRecorder()
        let sut = Self.makeCoalescer(clock: clock, recorder: rec)

        sut.enqueue(Self.grab(.radarr, "Movie A"))
        #expect(rec.calls.count == 1, "a movie grab must not wait")
        #expect(rec.calls.first?.items.count == 1)

        sut.enqueue(Self.grab(.radarr, "Movie B"))
        #expect(rec.calls.count == 1, "the tail must not fire its own banner")

        clock.advance(by: 9)                      // past the 8 s burst window
        #expect(rec.calls.count == 2, "the tail must arrive as one follow-up batch")
        #expect(rec.calls.last?.items.count == 1)
    }

    // MARK: - Per-source isolation

    @Test("A movie burst and a series burst don't interfere")
    func burstsAreTrackedPerSource() {
        let clock = VirtualClock()
        let rec = DeliveryRecorder()
        let sut = Self.makeCoalescer(clock: clock, recorder: rec)

        sut.enqueue(Self.grab(.sonarr, "Ep1"))
        sut.enqueue(Self.grab(.radarr, "Movie"))   // must be instant despite the held series group
        sut.enqueue(Self.grab(.sonarr, "Ep2"))

        #expect(rec.calls.count == 1, "the movie should already be out while the series waits")
        #expect(rec.calls.first?.source == .radarr)

        clock.advance(by: 11)                      // past both the 8 s burst window and the 5 s hold
        let movies = rec.calls(for: .radarr)
        let series = rec.calls(for: .sonarr)
        #expect(movies.count == 1)
        #expect(movies.first?.items.count == 1)
        #expect(series.count == 1, "the series group must still be a single delivery")
        #expect(series.first?.items.count == 2)
    }
}

/// The three-line shape of a queue banner.
///
/// Asserts on *structure* rather than on wording: `swift test` does not compile
/// the string catalog, so every localized label here comes back as its own key.
/// That is fine — what this suite protects is which facts land on which line,
/// and which facts are no longer there at all.
@MainActor
@Suite struct NotificationContentTests {
    private static func item(
        source: QueueItem.Source = .radarr,
        title: String = "Sintel (2010)",
        season: Int? = nil, episode: Int? = nil,
        quality: String? = "WEB-DL 1080p",
        size: Int64 = 4_500_000_000,
        formats: [String] = ["AMZN", "Atmos", "DDP 5.1", "x264"],
        score: Int = 720,
        isUpgrade: Bool = false,
        existingScore: Int? = nil
    ) -> QueueItem {
        QueueItem(
            id: "test", source: source, arrQueueId: 1,
            downloadId: nil, downloadProtocol: .usenet, downloadClient: "SABnzbd",
            title: title, subtitle: nil,
            seasonNumber: season, episodeNumber: episode,
            status: .downloading, progress: 0,
            sizeTotal: size, sizeLeft: size, timeLeft: nil,
            customFormats: formats, customFormatScore: score,
            quality: quality, isUpgrade: isUpgrade,
            existingCustomFormatScore: existingScore,
            contentSlug: nil
        )
    }

    /// The title line is the title and nothing else — no arr name, no status.
    /// The year is already baked in upstream by every arr client.
    @Test func titleIsTheTitleVerbatim() {
        let content = Self.item()
        #expect(content.title == "Sintel (2010)")
    }

    /// The tags were the line that never fit. Nothing may put them back.
    @Test func customFormatTagsAreGone() {
        let body = NotificationCoalescer.bodyText(for: Self.item())
        #expect(!body.contains("AMZN"))
        #expect(!body.contains("["))
        #expect(!body.contains("\n"), "the body is one line now")
    }

    /// Order matters: the score belongs next to the quality it qualifies, not
    /// tacked on after the size.
    @Test func bodyReadsQualityThenScoreThenSize() {
        let body = NotificationCoalescer.bodyText(for: Self.item())
        let fields = body.components(separatedBy: " · ")
        #expect(fields.count == 3, "expected three fields, got \(body)")
        #expect(fields[0] == "WEB-DL 1080p")
        #expect(fields[1] == "+720")
        #expect(fields[2].contains("GB"))
    }

    /// An upgrade spends the score slot on the move it makes, in place — the
    /// middle line stays the event and never carries numbers.
    @Test func upgradeShowsTheScoreMoveInTheScoreSlot() {
        let upgrade = Self.item(isUpgrade: true, existingScore: 60)
        let subtitle = NotificationCoalescer.subtitleText(for: upgrade)
        let fields = NotificationCoalescer.bodyText(for: upgrade)
            .components(separatedBy: " · ")
        #expect(!subtitle.contains("+"), "no scores on the middle line: \(subtitle)")
        #expect(fields.count == 3)
        #expect(fields[1] == "+60 → +720")
    }

    /// An upgrade the arr couldn't attribute to an existing file has nothing to
    /// move *from*, so it falls back to the plain score rather than half a move.
    @Test func upgradeWithoutAnOldScoreFallsBackToThePlainScore() {
        let upgrade = Self.item(isUpgrade: true, existingScore: nil)
        #expect(NotificationCoalescer.scoreMoveText(for: upgrade) == nil)
        let fields = NotificationCoalescer.bodyText(for: upgrade)
            .components(separatedBy: " · ")
        #expect(fields[1] == "+720")
    }

    @Test func episodeCoordinatesLandOnTheMiddleLine() {
        let episode = Self.item(source: .sonarr, title: "Pioneer One (2010)",
                                season: 1, episode: 3)
        #expect(NotificationCoalescer.subtitleText(for: episode).contains("S01E03"))
    }

    /// A movie has no finer coordinate, so the slot is simply absent rather
    /// than rendering a dangling separator.
    @Test func aMovieHasNoEpisodeSlot() {
        let movie = Self.item()
        #expect(NotificationCoalescer.episodeCode(for: movie) == nil)
        let subtitle = NotificationCoalescer.subtitleText(for: movie)
        #expect(!subtitle.contains("·"), "one label, no separators: \(subtitle)")
    }

    /// A season pack knows its season but no single episode.
    @Test func aSeasonPackShowsTheSeasonAlone() {
        let pack = Self.item(source: .sonarr, season: 2, episode: nil)
        #expect(NotificationCoalescer.episodeCode(for: pack) == "S02")
    }

    /// Missing fields drop out instead of leaving empty separators behind.
    @Test func absentFieldsLeaveNoEmptySeparators() {
        let sparse = Self.item(quality: nil, size: 0, score: 0)
        #expect(NotificationCoalescer.bodyText(for: sparse) == "0")
    }

    /// The score is the one field with no "missing" state — a release with no
    /// custom formats scores zero, which is a fact, not a gap.
    @Test func aZeroScoreStillHoldsItsSlot() {
        let plain = Self.item(formats: [], score: 0)
        let fields = NotificationCoalescer.bodyText(for: plain)
            .components(separatedBy: " · ")
        #expect(fields.count == 3)
        #expect(fields[1] == "0")
    }

    /// A batch reports what the whole group weighs, not the first item's size.
    @Test func batchBodyIsTheGroupTotal() {
        let items = [Self.item(size: 1_000_000_000), Self.item(size: 3_000_000_000)]
        let body = NotificationCoalescer.batchBodyText(items)
        #expect(body.contains("4"), "1 GB + 3 GB should read as 4 GB, got \(body)")
    }

    /// Failures outrank grabs in the notification summary.
    @Test func failuresOutrankGrabsForRelevance() {
        #expect(NotificationCoalescer.relevance(for: .failed)
                > NotificationCoalescer.relevance(for: .paused))
        #expect(NotificationCoalescer.relevance(for: .paused)
                > NotificationCoalescer.relevance(for: .downloading))
    }
}
