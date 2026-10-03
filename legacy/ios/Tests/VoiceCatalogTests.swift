import AVFoundation
import XCTest
@testable import KemoSabe

final class VoiceCatalogTests: XCTestCase {
    func testRankingExcludesNonEnglishNoveltyAndPersonalVoices() {
        let ranked = VoiceCatalog.ranked([
            option("us", "Ava", "en-US", .enhanced),
            option("fr", "Thomas", "fr-FR", .premium),
            option("novelty", "Bells", "en-US", .premium, novelty: true),
            option("personal", "Mine", "en-US", .premium, personal: true)
        ], preferredLanguage: "en-US", systemDefaultIdentifier: nil)

        XCTAssertEqual(ranked.map(\.identifier), ["us"])
    }

    func testRankingPrefersQualityThenExactLocaleThenSystemDefault() {
        let ranked = VoiceCatalog.ranked([
            option("standard-us", "A", "en-US", .standard),
            option("enhanced-uk", "Z", "en-GB", .enhanced),
            option("enhanced-default", "Z", "en_US", .enhanced),
            option("enhanced-us", "A", "en-US", .enhanced),
            option("premium-au", "Z", "en-AU", .premium)
        ], preferredLanguage: "en-US-u-hc-h12", systemDefaultIdentifier: "enhanced-default")

        XCTAssertEqual(ranked.map(\.identifier), [
            "premium-au", "enhanced-default", "enhanced-us", "enhanced-uk", "standard-us"
        ])
    }

    func testSelectionUsesKnownChoiceAndFallsBackForMissingChoice() {
        let choices = [
            option("best", "A", "en-US", .premium),
            option("other", "B", "en-GB", .enhanced)
        ]
        XCTAssertEqual(VoiceCatalog.selectedIdentifier("other", from: choices), "other")
        XCTAssertEqual(VoiceCatalog.selectedIdentifier("not-installed", from: choices), "best")
        XCTAssertEqual(VoiceCatalog.selectedIdentifier(nil, from: choices), "best")
        XCTAssertNil(VoiceCatalog.selectedIdentifier("not-installed", from: []))
    }

    func testSpeechPreparationPreservesNumbersDecimalsCodesAndAcronyms() {
        let text = "Dose 12.5 mg. Order AB-204, ask the U.S. team, and keep v2_1."
        XCTAssertEqual(SpeechText.prepared(text), text)
    }

    func testSpeechPreparationRemovesMarkdownAndReplacesURLsWithoutLosingPunctuation() {
        let text = "# Today\n- Read **the [care notes](https://example.com/a)**.\n- Open https://example.com/b?x=1, then use `AB-204`."
        XCTAssertEqual(SpeechText.prepared(text), "Today Read the care notes. Open the link, then use AB-204.")
    }

    func testUtteranceUsesPreparedTextAndSharedProsody() {
        let utterance = VoiceCatalog.utterance(for: "**Hello** from https://example.com.", voiceID: "missing", rate: 0.99)
        XCTAssertEqual(utterance.speechString, "Hello from the link.")
        XCTAssertEqual(utterance.rate, 0.56, accuracy: 0.0001)
        XCTAssertEqual(utterance.pitchMultiplier, 1)
        XCTAssertEqual(utterance.preUtteranceDelay, 0)
        XCTAssertEqual(utterance.postUtteranceDelay, 0)
    }

    private func option(
        _ identifier: String,
        _ name: String,
        _ language: String,
        _ quality: VoiceCatalog.Option.Quality,
        novelty: Bool = false,
        personal: Bool = false
    ) -> VoiceCatalog.Option {
        .init(identifier: identifier, name: name, language: language, quality: quality,
              isNovelty: novelty, isPersonal: personal)
    }
}
