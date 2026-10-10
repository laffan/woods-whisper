import XCTest
@testable import WoodsWhisperKit

final class RevisionTextTests: XCTestCase {

    func testUntouchedTextHasNoChanges() {
        let revision = RevisionText("  The quick brown fox.  ")
        XCTAssertEqual(revision.tokens.map(\.word), ["The", "quick", "brown", "fox."])
        XCTAssertEqual(revision.revisedText, "The quick brown fox.")
        XCTAssertFalse(revision.hasChanges)
    }

    func testStruckWordsAreLeftOutOfWhatsSaved() {
        var revision = RevisionText("The quick brown fox jumps.")
        revision.setStruck(true, in: 1...2)
        XCTAssertEqual(revision.revisedText, "The fox jumps.")
        XCTAssertTrue(revision.hasChanges)
        XCTAssertEqual(revision.struckRun(around: 2), 1...2)
        XCTAssertNil(revision.struckRun(around: 3))

        revision.setStruck(false, in: 1...2)
        XCTAssertFalse(revision.hasChanges)
    }

    func testStrikingTheEndOfALineKeepsTheLineBreak() {
        var revision = RevisionText("First line end\nSecond line")
        revision.setStruck(true, in: 2...2)
        XCTAssertEqual(revision.revisedText, "First line\nSecond line")
    }

    func testReplacingMidSentenceFitsTheSentence() {
        var revision = RevisionText("The quick brown fox jumps.")
        let edit = revision.beginReplacing(1...2)
        XCTAssertTrue(revision.hasPendingEdit)
        revision.finish(edit, with: "Slow red.")
        XCTAssertEqual(revision.revisedText, "The slow red fox jumps.")
        XCTAssertFalse(revision.hasPendingEdit)
        XCTAssertEqual(revision.tokens.filter(\.isNew).map(\.word), ["slow", "red"])
    }

    func testReplacementKeepsTheReplacedWordsClosingPunctuation() {
        var revision = RevisionText("I saw a cat.")
        let edit = revision.beginReplacing(3...3)
        revision.finish(edit, with: "Dog")
        XCTAssertEqual(revision.revisedText, "I saw a dog.")
    }

    func testInsertingBetweenWords() {
        var revision = RevisionText("Hello world.")
        let edit = revision.beginInserting(at: 1)
        XCTAssertEqual(revision.tokens.map(\.word), ["Hello", "…", "world."])
        revision.finish(edit, with: "Big")
        XCTAssertEqual(revision.revisedText, "Hello big world.")
    }

    func testInsertingAtTheEndStartsANewSentence() {
        var revision = RevisionText("Hello world.")
        let edit = revision.beginInserting(at: 2)
        revision.finish(edit, with: "and more")
        XCTAssertEqual(revision.revisedText, "Hello world. And more")
    }

    func testNothingSaidPutsTheTextBack() {
        var revision = RevisionText("Hello world.")
        let replace = revision.beginReplacing(0...0)
        revision.finish(replace, with: nil)
        let insert = revision.beginInserting(at: 2)
        revision.finish(insert, with: "   ")
        XCTAssertFalse(revision.hasPendingEdit)
        XCTAssertFalse(revision.hasChanges)
        XCTAssertEqual(revision.tokens.map(\.word), ["Hello", "world."])
    }

    func testWordsThatStayCapitalised() {
        XCTAssertEqual(RevisionText.decapitalized("I'm"), "I'm")
        XCTAssertEqual(RevisionText.decapitalized("I"), "I")
        XCTAssertEqual(RevisionText.decapitalized("NASA"), "NASA")
        XCTAssertEqual(RevisionText.decapitalized("Slow"), "slow")
        XCTAssertEqual(RevisionText.capitalized("and"), "And")
    }
}
