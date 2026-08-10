import Testing
import SwiftUI
@testable import ArrCore

/// One number, one meaning. Every surface that prints a custom-format score
/// now goes through `ScoreLabel`, so the two questions it answers — "what
/// does the sign look like" and "what does the colour mean" — are pinned
/// here rather than re-decided in each view.
@Suite("Score formatting")
struct ScoreFormattingTests {

    @Test("An absolute score carries a plus only when positive")
    func absoluteText() {
        #expect(ScoreLabel.text(465) == "+465")
        #expect(ScoreLabel.text(-12) == "-12")
        #expect(ScoreLabel.text(0) == "0")
    }

    /// A change of nothing is not the same statement as a score of nothing,
    /// and in a diff both can appear on the same row.
    @Test("A delta of zero reads as a wash, not as a zero score")
    func deltaText() {
        #expect(ScoreLabel.deltaText(125) == "+125")
        #expect(ScoreLabel.deltaText(-125) == "-125")
        #expect(ScoreLabel.deltaText(0) == "±0")
    }

    @Test("Absolute colour follows the sign of the value")
    func absoluteColour() {
        #expect(ScoreLabel.color(465) == .green)
        #expect(ScoreLabel.color(-12) == .red)
        #expect(ScoreLabel.color(0) == .secondary)
    }

    /// The bug this rule exists to prevent: the old diff painted every delta
    /// green unconditionally, so an upgrade that LOST points announced itself
    /// as a win.
    @Test("A losing change is never green")
    func losingDeltaIsRed() {
        #expect(ScoreLabel.deltaColor(-125) == .red)
        #expect(ScoreLabel.deltaColor(125) == .green)
        #expect(ScoreLabel.deltaColor(0) == .secondary)
    }

    /// Direction, not sign. Two negative scores can still describe a gain —
    /// the case the old sign-based colouring got backwards.
    @Test("A gain between two negative scores reads as a gain")
    func negativeToLessNegativeIsAGain() {
        let from = -500, to = -200
        #expect(ScoreLabel.deltaColor(to - from) == .green)
        // …while the value itself is still a negative score.
        #expect(ScoreLabel.color(to) == .red)
    }
}

/// The baseline rule: where a surface knows the file this one would replace,
/// the colour answers "better than what I have?" instead of "is the number
/// positive?". Both questions are useful; only one of them is useful when
/// there's something to compare against.
@Suite("Score colour against a baseline")
struct ScoreBaselineTests {

    /// The case that motivated the rule: on a manual search the pinned
    /// current-file header says +465, and a +120 release is a downgrade —
    /// it must not read as a win just because its own number is positive.
    @Test("A positive score below the baseline reads as a downgrade")
    func positiveButWorseIsRed() {
        #expect(ScoreLabel.deltaColor(120 - 465) == .red)
    }

    @Test("A positive score above the baseline reads as an upgrade")
    func positiveAndBetterIsGreen() {
        #expect(ScoreLabel.deltaColor(600 - 465) == .green)
    }

    /// Symmetrically, a negative score can be the better option.
    @Test("A negative score above the baseline still reads as an upgrade")
    func negativeButBetterIsGreen() {
        #expect(ScoreLabel.deltaColor(-200 - (-500)) == .green)
    }

    @Test("Matching the baseline is neither a win nor a loss")
    func levelIsNeutral() {
        #expect(ScoreLabel.deltaColor(465 - 465) == .secondary)
    }

    /// With no baseline the sign is all there is to say, so the fallback has
    /// to stay exactly the old behaviour.
    @Test("Without a baseline the colour falls back to the sign")
    func noBaselineFallsBackToSign() {
        #expect(ScoreLabel.color(120) == .green)
        #expect(ScoreLabel.color(-120) == .red)
    }
}
