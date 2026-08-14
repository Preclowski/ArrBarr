import Foundation

/// Drawing a progress bar between two readings.
///
/// The queue is polled every 30 seconds and pushed at by SignalR in between —
/// but Servarr's `queue` push is payload-free, so it says *that* something
/// changed, never how far along it now is. A bar that only moved on the poll
/// would sit dead still for half a minute and then jump, which reads as a
/// frozen app rather than a slow one.
///
/// So the bar is drawn from the last measurement plus the rate that was true
/// at the time. Two rules keep the estimate honest:
///
/// 1. **It never claims completion.** Reaching 100% is a fact about the
///    server's disk, and the only place that fact exists is a real reading.
///    The estimate stops just short and waits.
/// 2. **It expires.** Past `maxExtrapolation` the last reading is too old to
///    extrapolate from — the connection may be gone, the download stalled —
///    and the bar holds at the last honest position instead of drifting off
///    into fiction.
public extension QueueItem {

    /// Fraction of the download gained per second, or nil when it cannot be
    /// known — which is most rows: only something actively downloading has a
    /// rate at all.
    ///
    /// Prefers the download client's byte rate. Falls back to the arr's own
    /// ETA, which every client's rows carry, so the bar still moves for
    /// clients that report no per-item speed (SABnzbd).
    var progressRatePerSecond: Double? {
        guard status == .downloading, progress < 1 else { return nil }
        if let speed = downloadSpeed, speed > 0, sizeTotal > 0 {
            return Double(speed) / Double(sizeTotal)
        }
        if let seconds = Self.seconds(fromTimeLeft: timeLeft), seconds > 0 {
            return (1 - progress) / seconds
        }
        return nil
    }

    /// Whether this row's bar should be redrawn on a clock rather than only on
    /// a fetch. Views use it to avoid putting every paused and queued row in a
    /// queue of hundreds on a one-second timer.
    var isInterpolatingProgress: Bool { progressRatePerSecond != nil }

    /// The progress to draw at `date`, given when the row was fetched.
    ///
    /// `measuredAt` is the fetch's timestamp rather than a field on the row:
    /// every row in a snapshot was measured at the same moment, and storing it
    /// per row made two otherwise-identical rows fetched a second apart compare
    /// unequal — which is what SwiftUI diffing and change detection run on.
    ///
    /// Returns the measured value unchanged whenever there is no rate, the
    /// reading has expired, or the clock has run backwards — so a caller that
    /// passes this through unconditionally behaves exactly as before wherever
    /// interpolation doesn't apply.
    func interpolatedProgress(at date: Date, measuredAt: Date) -> Double {
        guard let rate = progressRatePerSecond else { return progress }
        let elapsed = date.timeIntervalSince(measuredAt)
        guard elapsed > 0, elapsed <= Self.maxExtrapolation else { return progress }
        return min(progress + rate * elapsed, Self.completionCeiling)
    }

    /// How long a reading may be extrapolated from. Two poll intervals: one
    /// missed fetch is a hiccup worth riding through, two is evidence that
    /// something is wrong and the bar should stop inventing movement.
    static var maxExtrapolation: TimeInterval { 60 }

    /// The estimate approaches but never reaches 1.0 — see rule 1 above.
    static var completionCeiling: Double { 0.99 }

    /// Seconds in an arr's `timeleft`, which is `HH:MM:SS` and may carry days
    /// as `D.HH:MM:SS` (.NET's `TimeSpan` format). Returns nil for anything
    /// else, including the "00:00:00" a finished row carries.
    static func seconds(fromTimeLeft raw: String?) -> TimeInterval? {
        guard let raw, !raw.isEmpty else { return nil }
        var rest = raw[...]
        var days: Double = 0
        // "1.02:03:04" — the day part is separated by a dot, and the fractional
        // seconds some builds append use one too, so only a leading dot before
        // the first colon counts.
        if let dot = rest.firstIndex(of: "."), let colon = rest.firstIndex(of: ":"), dot < colon {
            days = Double(rest[..<dot]) ?? 0
            rest = rest[rest.index(after: dot)...]
        }
        let parts = rest.split(separator: ":").map { Double($0.split(separator: ".").first ?? "") }
        guard parts.count == 3, let h = parts[0], let m = parts[1], let s = parts[2] else { return nil }
        let total = days * 86_400 + h * 3_600 + m * 60 + s
        return total > 0 ? total : nil
    }
}
