import Foundation

nonisolated extension Double {
    /// One decimal in the reader's locale: 7.5 in English, 7,5 in Polish.
    var ratingText: String { formatted(.number.precision(.fractionLength(1))) }
}

nonisolated extension Int {
    /// Minutes with the unit in the reader's language ("105 min").
    var runtimeText: String {
        Measurement(value: Double(self), unit: UnitDuration.minutes).formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }
}
