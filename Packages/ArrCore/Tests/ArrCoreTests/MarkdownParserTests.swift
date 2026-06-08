import Testing
@testable import ArrCore

@Suite("MarkdownParser")
struct MarkdownParserTests {
    @Test("Paragraph stays a paragraph")
    func paragraph() {
        #expect(MarkdownParser.blocks("Hello **world**") == [.paragraph(text: "Hello **world**")])
    }

    @Test("Bullets, numbered, headings, code parse into blocks")
    func blocks() {
        let md = """
        # Title
        - first
        - second
        1. one
        2. two
        ```
        code line
        ```
        plain paragraph
        """
        let blocks = MarkdownParser.blocks(md)
        #expect(blocks.contains(.heading(level: 1, text: "Title")))
        #expect(blocks.contains(.bullet(text: "first")))
        #expect(blocks.contains(.bullet(text: "second")))
        #expect(blocks.contains(.numbered(label: "1.", text: "one")))
        #expect(blocks.contains(.numbered(label: "2.", text: "two")))
        #expect(blocks.contains(.code(text: "code line")))
        #expect(blocks.contains(.paragraph(text: "plain paragraph")))
    }

    @Test("A bare '#1' is not a heading and '* x' needs the space")
    func notHeadingOrBullet() {
        #expect(MarkdownParser.blocks("#1 pick") == [.paragraph(text: "#1 pick")])
        #expect(MarkdownParser.blocks("2*3 = 6") == [.paragraph(text: "2*3 = 6")])
    }
}
