import Testing
import Foundation
@testable import ArrCore

@Suite("Chat in-text links")
struct ChatLinkTests {
    @Test("A media link parses into its external ref")
    func mediaLink() {
        #expect(ChatLink(url: URL(string: "arrbarr://media/tmdb:68718")!) == .media(.tmdb(68718)))
        #expect(ChatLink(url: URL(string: "arrbarr://media/tvdb:121361")!) == .media(.tvdb(121361)))
        #expect(ChatLink(url: URL(string: "arrbarr://media/imdb:tt0083658")!) == .media(.imdb("tt0083658")))
    }

    @Test("A person link parses, with the name when one is attached")
    func personLink() {
        #expect(ChatLink(url: URL(string: "arrbarr://person/19292")!) == .person(id: 19292, name: ""))
        #expect(ChatLink(url: URL(string: "arrbarr://person/19292?name=Adam%20Sandler")!)
                == .person(id: 19292, name: "Adam Sandler"))
    }

    @Test("Anything malformed is not a link at all")
    func rejectsGarbage() {
        // A hallucinated id shape, an unknown host, a missing value, a foreign
        // scheme — none of these may become a tappable in-app link.
        #expect(ChatLink(url: URL(string: "arrbarr://media/nope:12")!) == nil)
        #expect(ChatLink(url: URL(string: "arrbarr://cast/19292")!) == nil)
        #expect(ChatLink(url: URL(string: "arrbarr://person/")!) == nil)
        #expect(ChatLink(url: URL(string: "arrbarr://person/zero")!) == nil)
        #expect(ChatLink(url: URL(string: "arrbarr://person/0")!) == nil)
        #expect(ChatLink(url: URL(string: "https://themoviedb.org/person/19292")!) == nil)
    }

    @Test("URL form round-trips")
    func roundTrip() {
        let cases: [ChatLink] = [
            .media(.tmdb(68718)),
            .media(.musicBrainz("83d91898-7763-47d7-b03b-b92132375c47")),
            .person(id: 19292, name: "Adam Sandler"),
            .person(id: 19292, name: ""),
        ]
        for link in cases {
            let url = try! #require(link.url)
            #expect(ChatLink(url: url) == link)
        }
    }

    @Test("A nameless person link picks up the link's own text")
    func stampsNameFromLabel() {
        let url = URL(string: "arrbarr://person/19292")!
        let named = MarkdownMessage.namingPersonLinks(url, label: "Adam Sandler")
        #expect(ChatLink(url: named) == .person(id: 19292, name: "Adam Sandler"))
    }

    @Test("Stamping leaves everything that isn't a nameless person link alone")
    func leavesOtherLinksAlone() {
        let media = URL(string: "arrbarr://media/tmdb:68718")!
        #expect(MarkdownMessage.namingPersonLinks(media, label: "Sicario") == media)

        let web = URL(string: "https://example.com")!
        #expect(MarkdownMessage.namingPersonLinks(web, label: "Example") == web)

        // An explicit name in the URL wins over the link text.
        let named = URL(string: "arrbarr://person/19292?name=Adam%20Sandler")!
        #expect(MarkdownMessage.namingPersonLinks(named, label: "he") == named)
    }
}

@Suite("Chat link verification")
struct ChatLinkVerificationTests {
    private func toolMessage(_ text: String) -> ChatMessage {
        ChatMessage(role: .tool, content: "some_tool", toolResult: text)
    }

    @Test("Ids printed by a tool are the ones that count as known")
    func harvestsIdsFromToolResults() {
        let messages = [
            ChatMessage(role: .user, content: "co gra Tilda"),
            toolMessage("Resolved 'tilda' → Tilda Swinton (personId: 3063).\n- Orlando (1992) — tmdb:20789"),
            toolMessage("• Andor — in library as Andor, seriesId=12, tvdb:404174, downloaded"),
        ]
        let known = ChatLinkVerification.knownKeys(in: messages)
        #expect(known.contains("tmdb:20789"))
        #expect(known.contains("tvdb:404174"))
        #expect(known.contains("person:3063"))
    }

    @Test("A link the tools never mentioned is not verified")
    func rejectsInventedIds() {
        // The reported failure: an answer full of films check_titles only ever
        // saw as names, linked to ids straight out of the model's memory.
        let known = ChatLinkVerification.knownKeys(in: [toolMessage("• Orlando (1992) — NOT in library (no id — do not link this title)")])
        #expect(known.isEmpty)
        #expect(!ChatLinkVerification.isVerified(.media(.tmdb(889)), against: known))
        #expect(!ChatLinkVerification.isVerified(.person(id: 3063, name: "Tilda"), against: known))
    }

    @Test("imdb ids match whichever way the tool printed them")
    func normalisesImdb() {
        let known = ChatLinkVerification.knownKeys(in: [toolMessage("Blade Runner — imdb:0083658")])
        #expect(ChatLinkVerification.isVerified(.media(.imdb("tt0083658")), against: known))
    }

    @Test("Only tool results are harvested — not the model's own prose")
    func ignoresAssistantText() {
        // Otherwise a made-up id would verify itself the moment the model wrote
        // it into the same message as the link.
        let messages = [ChatMessage(role: .assistant, content: "Orlando — tmdb:889")]
        #expect(ChatLinkVerification.knownKeys(in: messages).isEmpty)
    }
}
