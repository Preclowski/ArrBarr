import Foundation

/// Renders the ETA an arr reports on a queue item.
///
/// Servarr serialises `timeleft` as a .NET `TimeSpan`, i.e. `[d.]hh:mm:ss[.fffffff]`.
/// The days separator and the fractional-seconds separator are *the same*
/// character, so the obvious "cut at the first dot to drop the fraction" trick
/// also decapitates anything longer than a day: `1.05:30:00` (1 day 5½ hours)
/// collapses to `"1"`, and the user sees an ETA of "1". Parse the actual shape
/// instead.
enum TimeLeftFormatter {

    /// A display-ready ETA, or `nil` when there is nothing worth showing: no
    /// value, blank, or a zero duration (a finished item shouldn't advertise
    /// "00:00:00").
    ///
    /// Input that isn't a TimeSpan at all is passed through verbatim — some
    /// sources hand us an already-humanised ETA ("12 min"), and echoing it
    /// beats dropping an ETA just because we didn't recognise the shape.
    static func format(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let span = timeSpan(trimmed) else { return trimmed }
        guard span.days > 0 || span.hours > 0 || span.minutes > 0 || span.seconds > 0 else { return nil }

        guard span.days > 0 else {
            return String(format: "%02d:%02d:%02d", span.hours, span.minutes, span.seconds)
        }
        // Seconds are noise a day out, so the multi-day form drops them:
        // "1d 05:30". Only the day suffix is language-dependent.
        let clock = String(format: "%02d:%02d", span.hours, span.minutes)
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "%1$dd %2$@", bundle: .module,
                comment: "ETA over a day. %1$d is whole days followed by the day-unit abbreviation; %2$@ is hh:mm."
            ),
            span.days, clock
        )
    }

    /// Splits `[d.]hh:mm:ss[.fffffff]` into its integer fields, or `nil` when
    /// the string isn't that shape.
    private static func timeSpan(_ s: String) -> (days: Int, hours: Int, minutes: Int, seconds: Int)? {
        let fields = s.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }

        // Head is `hh` or `d.hh` — the *first* dot separates the days.
        var head = fields[0]
        var days = 0
        if let dot = head.firstIndex(of: ".") {
            guard let parsed = Int(head[..<dot]) else { return nil }
            days = parsed
            head = head[head.index(after: dot)...]
        }
        // Tail is `ss` or `ss.fffffff` — here the dot really is the fraction.
        let tail = fields[2].prefix { $0 != "." }

        guard let hours = Int(head),
              let minutes = Int(fields[1]),
              let seconds = Int(tail) else { return nil }
        return (days, hours, minutes, seconds)
    }
}
