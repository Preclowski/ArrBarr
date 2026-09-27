import Foundation

/// The bar is drawn from the last reading plus its rate, because Servarr's `queue`
/// push is payload-free and the poll is 30 s. It never claims 100% and expires after `maxExtrapolation`.
nonisolated public extension QueueItem {

    /// Falls back to the arr's ETA so the bar still moves for clients that
    /// report no per-item speed (SABnzbd).
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

    /// Keeps paused and queued rows off a one-second redraw timer.
    var isInterpolatingProgress: Bool { progressRatePerSecond != nil }

    /// `measuredAt` is passed in rather than stored per row: a per-row timestamp
    /// made otherwise-identical rows compare unequal for SwiftUI diffing.
    func interpolatedProgress(at date: Date, measuredAt: Date) -> Double {
        guard let rate = progressRatePerSecond else { return progress }
        let elapsed = date.timeIntervalSince(measuredAt)
        guard elapsed > 0, elapsed <= Self.maxExtrapolation else { return progress }
        return min(progress + rate * elapsed, Self.completionCeiling)
    }

    /// Two poll intervals: one missed fetch is a hiccup, two means something is wrong.
    static var maxExtrapolation: TimeInterval { 60 }

    /// Completion is only ever a real reading, never an estimate.
    static var completionCeiling: Double { 0.99 }

    /// `timeleft` is .NET `TimeSpan` (`D.HH:MM:SS`). nil for the "00:00:00" a
    /// finished row carries.
    static func seconds(fromTimeLeft raw: String?) -> TimeInterval? {
        guard let raw, !raw.isEmpty else { return nil }
        var rest = raw[...]
        var days: Double = 0
        // Fractional seconds also use a dot, so only a dot before the first colon is days.
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
