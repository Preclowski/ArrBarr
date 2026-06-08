import Testing
import Foundation
@testable import ArrCore

@Suite("Chat spoiler markup parsing")
struct ChatSpoilerMarkupTests {
    @Test("Plain text is one text segment")
    func plainText() {
        #expect(ChatSpoilerMarkup.parse("hello world") == [.text("hello world")])
    }

    @Test("Empty string yields no segments")
    func empty() {
        #expect(ChatSpoilerMarkup.parse("") == [])
    }

    @Test("A spoiler in the middle splits into three segments, preserving surrounding whitespace")
    func midSpoiler() {
        #expect(ChatSpoilerMarkup.parse("before ||secret|| after")
                == [.text("before "), .spoiler("secret"), .text(" after")])
    }

    @Test("Leading spoiler")
    func leadingSpoiler() {
        #expect(ChatSpoilerMarkup.parse("||a|| rest")
                == [.spoiler("a"), .text(" rest")])
    }

    @Test("Trailing spoiler")
    func trailingSpoiler() {
        #expect(ChatSpoilerMarkup.parse("rest ||a||")
                == [.text("rest "), .spoiler("a")])
    }

    @Test("Multiple spoilers")
    func multiple() {
        #expect(ChatSpoilerMarkup.parse("||one|| and ||two||")
                == [.spoiler("one"), .text(" and "), .spoiler("two")])
    }

    @Test("Unterminated marker stays literal text")
    func unterminated() {
        #expect(ChatSpoilerMarkup.parse("oops ||no close") == [.text("oops ||no close")])
    }

    @Test("Empty spoiler body is treated as literal text, not a spoiler")
    func emptyBody() {
        #expect(ChatSpoilerMarkup.parse("a |||| b") == [.text("a |||| b")])
    }

    @Test("containsSpoiler detects a well-formed spoiler")
    func detects() {
        #expect(ChatSpoilerMarkup.containsSpoiler("the ||twist|| is here"))
        #expect(!ChatSpoilerMarkup.containsSpoiler("no spoilers here"))
        #expect(!ChatSpoilerMarkup.containsSpoiler("dangling ||open"))
    }
}
