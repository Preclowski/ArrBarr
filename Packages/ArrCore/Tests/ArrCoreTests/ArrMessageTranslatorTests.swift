import Foundation
import Testing
@testable import ArrCore

@Suite struct ArrMessageTranslatorTests {
    private let polish = Locale(identifier: "pl")

    private func pl(_ message: String) -> String {
        ArrMessageTranslator.translate(message, locale: polish)
    }

    @Test func aMessageWithoutPlaceholdersIsLookedUp() {
        #expect(pl("Wrong movie") == "Zły film")
        #expect(pl("Not an upgrade for existing movie file") == "To nie jest upgrade dla istniejącego pliku filmu")
    }

    @Test func placeholdersKeepTheArrsValues() {
        #expect(pl("Existing file on disk is of equal or higher preference: WEBDL-1080p v1")
                == "Plik na dysku ma równą lub wyższą preferencję: WEBDL-1080p v1")
        #expect(pl("Couldn't find similar album for [/data/downloads/album]")
                == "Nie znaleziono podobnego albumu dla [/data/downloads/album]")
    }

    @Test func theMostLiteralTemplateWins() {
        #expect(pl("2 GB is larger than maximum allowed 1 GB (for Big Buck Bunny)")
                == "2 GB to więcej niż dozwolone maksimum 1 GB (dla Big Buck Bunny)")
        #expect(pl("2 GB is larger than maximum allowed 1 GB") == "2 GB to więcej niż dozwolone maksimum 1 GB")
        #expect(pl("Original Language (English) is wanted, but found French")
                == "Oczekiwano języka oryginalnego (English), a znaleziono French")
    }

    @Test func positionalArgumentsCanChangeOrder() {
        #expect(pl("Episode 5 was unexpected considering the S01 folder name")
                == "Przy nazwie folderu S01 odcinek 5 jest nieoczekiwany")
    }

    @Test func aLiteralPercentSurvives() {
        let message = "Season pack does not meet the upgrade criteria. Upgradable: 3/10 (30%), Mode: Any, Threshold: 50%"
        #expect(pl(message) == "Paczka sezonu nie spełnia kryteriów upgrade'u. Do upgrade'u: 3/10 (30%), Tryb: Any, Próg: 50%")
        #expect(ArrMessageTranslator.translate(message, locale: Locale(identifier: "en")) == message)
    }

    /// The shape `ArrCompositions.flatten` writes for a reason only one file has.
    @Test func aFileNamePrefixIsKept() {
        #expect(pl("a.mkv: Wrong movie") == "a.mkv: Zły film")
        #expect(pl("Movie: The Sequel.mkv: Wrong movie") == "Movie: The Sequel.mkv: Zły film")
        #expect(pl("a.mkv: 720p is not wanted in profile") == "a.mkv: Profil nie dopuszcza 720p")
    }

    @Test func unknownTextComesBackUnchanged() {
        #expect(pl("Something a future arr says") == "Something a future arr says")
        #expect(pl("a.mkv: Something a future arr says") == "a.mkv: Something a future arr says")
        #expect(pl("") == "")
    }

    @Test(arguments: ["de", "es", "fr", "nl", "pl"])
    func everyTemplateIsTranslated(language: String) {
        let locale = Locale(identifier: language)
        let untranslated = ArrMessageTemplates.all.filter {
            AppLocalized.string($0, locale: locale, table: "ArrMessages") == $0
        }
        #expect(untranslated.isEmpty)
    }
}
