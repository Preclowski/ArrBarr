import Foundation
import Testing
@testable import ArrCore

/// Regressions in the three parsers every queue row is built from
/// (`RadarrClient.swift`, shared by all four arrs). Each one pins a defect that
/// reached users: a failed import painted as a green "Completed" pill, a crash
/// on an absurd byte count, and today's releases missing from Upcoming for
/// everyone west of Greenwich.
///
/// Deliberately separate from `ParsingTests` — those cover the happy paths that
/// already worked, these cover the ones that didn't.
@Suite("Queue status mapping regressions")
struct QueueStatusMappingRegressionTests {

    /// The headline bug. Once the bytes have landed, Servarr leaves `status`
    /// at "completed" no matter how badly the *import* then went — so every
    /// one of these used to fall through the tracked-state switch and render a
    /// green "Completed" pill on a grab that produced no file at all.
    @Test("Every failure spelling maps to .failed, even under status=completed",
          arguments: ["importFailed", "failed", "downloadFailedPending", "downloadFailed", "failedPending"])
    func failureStatesBeatCompleted(_ trackedState: String) {
        #expect(parseStatus(arrStatus: "completed", trackedState: trackedState) == .failed)
    }

    /// Case is arr-version dependent (`importFailed` vs `importfailed` in some
    /// payloads), and the parser lowercases before matching — pin that so a
    /// future rewrite can't reintroduce a case-sensitive compare.
    @Test("Failure spellings match case-insensitively")
    func failureStatesAreCaseInsensitive() {
        #expect(parseStatus(arrStatus: "completed", trackedState: "IMPORTFAILED") == .failed)
        #expect(parseStatus(arrStatus: "completed", trackedState: "DownloadFailedPending") == .failed)
    }

    /// `ignored` is the arr deliberately dropping a grab it can't match. Not an
    /// error — but emphatically not a completed download either, which is what
    /// it used to render as.
    @Test("An ignored grab is a warning, not a completion")
    func ignoredIsWarning() {
        #expect(parseStatus(arrStatus: "completed", trackedState: "ignored") == .warning)
        #expect(parseStatus(arrStatus: "completed", trackedState: "importBlocked") == .warning)
    }

    /// The backstop that makes the mapping future-proof: whatever Servarr
    /// invents next, `trackedDownloadStatus == "error"` means the grab is dead,
    /// and an unrecognised state must not be allowed to fall through to
    /// `status: "completed"` and go green again.
    @Test("An unknown tracked state with trackedDownloadStatus=error can't render as completed")
    func unknownStateWithErrorStatusFails() {
        #expect(parseStatus(arrStatus: "completed",
                            trackedState: "importDeferredUntilTuesday",
                            trackedStatus: "error") == .failed)
        // Same backstop with no tracked state at all — the plain
        // "completed + error" pair an older arr sends.
        #expect(parseStatus(arrStatus: "completed", trackedState: nil, trackedStatus: "error") == .failed)
        #expect(parseStatus(arrStatus: "completed", trackedState: nil, trackedStatus: "ERROR") == .failed)
    }

    /// The backstop is narrow on purpose: it only fires on "error". A healthy
    /// or merely-warned grab keeps whatever the state/status resolved to, so
    /// the fix can't turn ordinary rows red.
    @Test("The error backstop doesn't fire for ok / warning / absent")
    func backstopIsNarrow() {
        #expect(parseStatus(arrStatus: "completed", trackedState: "imported", trackedStatus: "ok") == .completed)
        #expect(parseStatus(arrStatus: "completed", trackedState: nil, trackedStatus: "warning") == .completed)
        #expect(parseStatus(arrStatus: "completed", trackedState: nil, trackedStatus: nil) == .completed)
        // …but where it does fire it outranks a terminal state too: a record
        // the arr flagged as errored is never shown as done, however the
        // tracked state reads.
        #expect(parseStatus(arrStatus: "completed", trackedState: "imported", trackedStatus: "error") == .failed)
    }
}

@Suite("Byte-count clamping")
struct ArrByteClampingTests {

    /// `Int64(someDouble)` traps on anything outside Int64's range, and `1e300`
    /// is perfectly legal JSON — so a buggy (or hostile) arr could kill the app
    /// with a single queue response. This test crashes the whole test *process*
    /// if the clamp is ever removed, which is the point.
    @Test("An absurd size clamps instead of trapping")
    func hugeSizeDoesNotTrap() {
        #expect(clampedBytes(1e300) == Int64.max)
        #expect(clampedBytes(Double.infinity) == Int64.max)
        // `Double(Int64.max)` rounds UP to exactly 2^63, i.e. one past the
        // representable maximum — the exact value the truncating initializer
        // would trap on.
        #expect(clampedBytes(Double(Int64.max)) == Int64.max)
    }

    @Test("Nonsense and negatives read as zero rather than a wild number")
    func nonsenseSizesAreZero() {
        #expect(clampedBytes(nil) == 0)
        #expect(clampedBytes(Double.nan) == 0)
        #expect(clampedBytes(-1) == 0)
        #expect(clampedBytes(-Double.infinity) == 0)
        #expect(clampedBytes(0) == 0)
    }

    @Test("Ordinary sizes pass through untouched")
    func realSizesSurvive() {
        #expect(clampedBytes(1_234) == 1_234)
        // ~8 GB — a normal season pack, and well inside Double's exact-integer
        // range, so no rounding is allowed to creep in.
        #expect(clampedBytes(8_589_934_592) == 8_589_934_592)
    }
}

/// The bug that hid today's releases across all of the Americas: a date-only
/// `releaseDate` was parsed as 00:00 **UTC**, which lands before local midnight
/// for every user at a negative offset — and Upcoming filters on
/// `Calendar.current.startOfDay(for: Date())`.
///
/// `.serialized` because the negative-offset case can only be exercised by
/// moving the process default time zone: `parseArrDate` reads `.current`
/// directly and takes no zone parameter.
@Suite("Arr date parsing — time zones", .serialized)
struct ArrDateParsingTimeZoneTests {

    /// Runs `body` with the process default time zone forced to `identifier`,
    /// restoring the real one afterwards. Kept synchronous (no `await` inside)
    /// so the window in which the global is moved is as short as possible.
    private func withTimeZone<T>(_ identifier: String, _ body: (TimeZone) throws -> T) rethrows -> T {
        // Force-unwrapped: a missing tzdata entry is a broken test host, and a
        // silent skip here would hide the very regression this file exists for.
        let zone = TimeZone(identifier: identifier)!
        let previous = NSTimeZone.default
        NSTimeZone.default = zone
        defer { NSTimeZone.default = previous }
        return try body(zone)
    }

    private func gregorian(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// UTC-8/-7 — the offset sign that made the bug visible.
    @Test("A title releasing TODAY still passes the Upcoming filter at a negative UTC offset")
    func todayIsUpcomingWestOfGreenwich() throws {
        try withTimeZone("America/Los_Angeles") { zone in
            let calendar = gregorian(in: zone)
            let now = Date()
            // Exactly the filter `QueueViewModel` / `QueueAggregator` apply.
            let startOfToday = calendar.startOfDay(for: now)

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd"

            let parsed = try #require(parseArrDate(formatter.string(from: now)))
            // Parsed as UTC midnight this is 16:00/17:00 *yesterday* locally,
            // so the row was filtered out and today's releases vanished.
            #expect(parsed >= startOfToday)
            // A calendar day anchors at LOCAL midnight, exactly.
            #expect(parsed == startOfToday)
        }
    }

    /// The mirror image: at a positive offset the old code accidentally worked
    /// (UTC midnight lands *after* local midnight), which is why the bug only
    /// ever showed up in bug reports from the Americas. Anchoring locally has
    /// to keep working here too.
    @Test("The same date still anchors at local midnight at a positive UTC offset")
    func localMidnightEastOfGreenwich() throws {
        try withTimeZone("Europe/Warsaw") { zone in
            let calendar = gregorian(in: zone)
            let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 22)))
            #expect(parseArrDate("2026-07-22") == expected)
        }
    }

    /// The other half of the date fix. `.NET` drops the "Z" when a `DateTime`'s
    /// Kind is unspecified, and `ISO8601DateFormatter` with `.withFullDate` is
    /// lenient enough to accept the whole string by matching only its date
    /// prefix — silently throwing the time away, so "airs at 20:00" rendered as
    /// midnight.
    @Test("A zone-less datetime keeps its time instead of collapsing to midnight")
    func zonelessDateTimeKeepsItsTime() throws {
        let parsed = try #require(parseArrDate("2026-03-15T20:00:00"))

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = try #require(
            utc.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 20, minute: 0, second: 0))
        )
        #expect(parsed == expected)

        // Spelled out separately so a failure says *what* went wrong rather
        // than just printing two timestamps.
        #expect(utc.component(.hour, from: parsed) == 20)
        #expect(utc.component(.day, from: parsed) == 15)
    }

    /// A zone-less datetime is an instant, not a calendar day, so it must NOT
    /// pick up the local-midnight treatment the date-only branch applies —
    /// otherwise fixing one shape would break the other.
    @Test("A zone-less datetime is read as UTC regardless of the local zone")
    func zonelessDateTimeIgnoresTheLocalZone() {
        let west = withTimeZone("America/Los_Angeles") { _ in parseArrDate("2026-03-15T20:00:00") }
        let east = withTimeZone("Europe/Warsaw") { _ in parseArrDate("2026-03-15T20:00:00") }
        #expect(west != nil)
        #expect(west == east)
    }
}
