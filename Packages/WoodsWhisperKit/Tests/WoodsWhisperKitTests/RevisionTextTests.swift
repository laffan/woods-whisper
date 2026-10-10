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
        let spoken = revision.finish(edit, with: "Slow red.")
        XCTAssertEqual(revision.revisedText, "The slow red fox jumps.")
        XCTAssertFalse(revision.hasPendingEdit)
        XCTAssertEqual(spoken.compactMap { id in revision.tokens.first { $0.id == id }?.word },
                       ["slow", "red"])
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

    func testMovingWordsForwardAndBack() {
        var revision = RevisionText("one two three four")
        let ids = revision.tokens[0...1].map(\.id)
        revision.move(0...1, to: 3)
        XCTAssertEqual(revision.revisedText, "three one two four")
        XCTAssertEqual(revision.tokens[1...2].map(\.id), ids)
        revision.move(1...2, to: 4)
        XCTAssertEqual(revision.revisedText, "three four one two")
        revision.move(2...3, to: 0)
        XCTAssertEqual(revision.revisedText, "one two three four")
    }

    func testMovingOntoItselfDoesNothing() {
        var revision = RevisionText("one two three")
        revision.move(1...1, to: 1)
        revision.move(1...1, to: 2)
        XCTAssertFalse(revision.hasChanges)
        XCTAssertFalse(RevisionText.moves(1...1, to: 2))
        XCTAssertTrue(RevisionText.moves(1...1, to: 3))
    }

    func testMovingTheEndOfALineKeepsTheLineBreak() {
        var revision = RevisionText("first end\nsecond line")
        revision.move(1...1, to: 4)
        XCTAssertEqual(revision.revisedText, "first\nsecond line end")
    }

    func testWordsThatStayCapitalised() {
        XCTAssertEqual(RevisionText.decapitalized("I'm"), "I'm")
        XCTAssertEqual(RevisionText.decapitalized("I"), "I")
        XCTAssertEqual(RevisionText.decapitalized("NASA"), "NASA")
        XCTAssertEqual(RevisionText.decapitalized("Slow"), "slow")
        XCTAssertEqual(RevisionText.capitalized("and"), "And")
    }
}
