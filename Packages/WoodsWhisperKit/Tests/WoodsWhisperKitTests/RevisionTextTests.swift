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

    func testDeletingWords() {
        var revision = RevisionText("The quick brown fox jumps.")
        revision.delete(1...2)
        XCTAssertEqual(revision.tokens.map(\.word), ["The", "fox", "jumps."])
        XCTAssertEqual(revision.revisedText, "The fox jumps.")
        XCTAssertTrue(revision.hasChanges)
    }

    func testDeletingTheEndOfALineKeepsTheLineBreak() {
        var revision = RevisionText("First line end\nSecond line")
        revision.delete(2...2)
        XCTAssertEqual(revision.revisedText, "First line\nSecond line")
    }

    func testReplacingEverythingStillComparesWithTheOriginal() {
        var revision = RevisionText("Hello world.")
        revision.replaceAll(with: "Goodbye world.")
        XCTAssertEqual(revision.revisedText, "Goodbye world.")
        XCTAssertTrue(revision.hasChanges)
        revision.replaceAll(with: "Hello world.")
        XCTAssertFalse(revision.hasChanges)
    }

    func testSentenceAroundAWord() {
        let revision = RevisionText("One two. Three four? Five\nSix seven")
        XCTAssertEqual(revision.sentence(around: 0), 0...1)
        XCTAssertEqual(revision.sentence(around: 1), 0...1)
        XCTAssertEqual(revision.sentence(around: 3), 2...3)
        // A line break ends a sentence that has no punctuation of its own.
        XCTAssertEqual(revision.sentence(around: 4), 4...4)
        XCTAssertEqual(revision.sentence(around: 6), 5...6)
        XCTAssertNil(revision.sentence(around: 7))
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

    func testRevisingAWholeBodyKeepsItsSections() {
        let recording = UUID()
        let old = [Document.Paragraph(text: "First section.", recordingID: recording),
                   Document.Paragraph(text: "Second section."),
                   Document.Paragraph(text: "Third section.")]
        // The first edited in place, the second struck out entirely, the third unchanged.
        let revised = Document.paragraphs(revising: "First part.\n\nThird section.", from: old)
        XCTAssertEqual(revised.map(\.text), ["First part.", "Third section."])
        XCTAssertEqual(revised[0].id, old[0].id)
        XCTAssertEqual(revised[0].recordingID, recording)
        XCTAssertEqual(revised[1].id, old[2].id)
    }

    func testStrikingTheEndOfASectionKeepsSectionsApart() {
        var revision = RevisionText("One two.\n\nThree four.")
        revision.setStruck(true, in: 1...1)
        XCTAssertEqual(Document.paragraphs(from: revision.revisedText).map(\.text), ["One", "Three four."])
    }

    func testSpokenCommands() {
        typealias Command = RevisionText.SpokenCommand
        XCTAssertEqual(Command("Period."), .mark("."))
        XCTAssertEqual(Command("Question mark?"), .mark("?"))
        XCTAssertEqual(Command(" comma, "), .mark(","))
        XCTAssertEqual(Command("Semi-colon."), .mark(";"))
        XCTAssertEqual(Command("Em-dash."), .mark("—"))
        XCTAssertEqual(Command("?"), .mark("?"))
        XCTAssertEqual(Command("Wrap in parentheses."), .wrap(.parentheses))
        XCTAssertEqual(Command("Wrap it in quotes"), .wrap(.quotes))
        XCTAssertEqual(Command("Wrap that in single quotes."), .wrap(.singleQuotes))
        XCTAssertEqual(Command("Rap in em dashes."), .wrap(.dashes))
        XCTAssertNil(Command("A comma goes here."))
        XCTAssertNil(Command("Wrap up the meeting."))
        XCTAssertNil(Command("Wrap in paper."))
    }

    func testSpeakingAMarkIntoAGapPutsItOnTheWordBefore() {
        var revision = RevisionText("I went home and I slept.")
        let edit = revision.beginInserting(at: 3)
        let touched = revision.finish(edit, with: "Comma.")
        XCTAssertEqual(revision.revisedText, "I went home, and I slept.")
        XCTAssertEqual(touched, [revision.tokens[2].id])
        XCTAssertFalse(revision.hasPendingEdit)
    }

    func testAFullStopCapitalisesTheNextWord() {
        var revision = RevisionText("I went home and I slept.")
        let edit = revision.beginInserting(at: 3)
        revision.finish(edit, with: "Period.")
        XCTAssertEqual(revision.revisedText, "I went home. And I slept.")
    }

    func testAMarkSpokenOverWordsGoesOnTheirEnd() {
        var revision = RevisionText("Is it home. It was.")
        let ids = revision.tokens[0...2].map(\.id)
        let edit = revision.beginReplacing(0...2)
        let touched = revision.finish(edit, with: "Question mark?")
        XCTAssertEqual(revision.revisedText, "Is it home? It was.")
        XCTAssertEqual(touched, ids)
        XCTAssertFalse(revision.hasPendingEdit)

        // Said again over the same words, the new mark takes the old one's place.
        let again = revision.beginReplacing(0...2)
        revision.finish(again, with: "Comma")
        XCTAssertEqual(revision.revisedText, "Is it home, it was.")
    }

    func testADashIsAWordOfItsOwn() {
        var revision = RevisionText("I saw a cat")
        let edit = revision.beginInserting(at: 2)
        revision.finish(edit, with: "Em dash.")
        XCTAssertEqual(revision.revisedText, "I saw — a cat")
    }

    func testWrappingInParenthesesAndQuotes() {
        var revision = RevisionText("I saw a cat, then left.")
        let edit = revision.beginReplacing(2...3)
        revision.finish(edit, with: "Wrap in parentheses.")
        XCTAssertEqual(revision.revisedText, "I saw (a cat), then left.")

        var whole = RevisionText("One. Two three.")
        let wrapSentence = whole.beginReplacing(1...2)
        whole.finish(wrapSentence, with: "Wrap it in quotes.")
        XCTAssertEqual(whole.revisedText, "One. “Two three.”")
    }

    func testWrappingInDashes() {
        var revision = RevisionText("I saw a cat, then left.")
        let ids = revision.tokens[2...3].map(\.id)
        let edit = revision.beginReplacing(2...3)
        let touched = revision.finish(edit, with: "Wrap in em dashes.")
        XCTAssertEqual(revision.revisedText, "I saw — a cat — then left.")
        XCTAssertEqual(touched, ids)

        // No closing dash after the end of a sentence.
        var end = RevisionText("I saw a cat.")
        let atEnd = end.beginReplacing(2...3)
        end.finish(atEnd, with: "Wrap in dashes")
        XCTAssertEqual(end.revisedText, "I saw — a cat.")
    }

    func testWrapSpokenIntoAGapIsWords() {
        var revision = RevisionText("Hello world.")
        let edit = revision.beginInserting(at: 1)
        revision.finish(edit, with: "Wrap in quotes")
        XCTAssertEqual(revision.revisedText, "Hello wrap in quotes world.")
    }

    func testWordsThatStayCapitalised() {
        XCTAssertEqual(RevisionText.decapitalized("I'm"), "I'm")
        XCTAssertEqual(RevisionText.decapitalized("I"), "I")
        XCTAssertEqual(RevisionText.decapitalized("NASA"), "NASA")
        XCTAssertEqual(RevisionText.decapitalized("Slow"), "slow")
        XCTAssertEqual(RevisionText.capitalized("and"), "And")
    }

    func testSpokenBoldAndItalic() {
        typealias Command = RevisionText.SpokenCommand
        XCTAssertEqual(Command("Wrap in bold."), .wrap(.bold))
        XCTAssertEqual(Command("Wrap it in italics"), .wrap(.italic))
    }

    func testInsertingAMarkFromTheMenu() {
        var revision = RevisionText("I went home and I slept.")
        let id = revision.insertMark("?", at: 3)
        XCTAssertEqual(revision.revisedText, "I went home? And I slept.")
        XCTAssertEqual(id, revision.tokens[2].id)

        // A mark at a gap with nothing before it stands on its own.
        var start = RevisionText("hello")
        start.insertMark(",", at: 0)
        XCTAssertEqual(start.revisedText, ", hello")
    }

    func testWrappingInBoldAndItalic() {
        var revision = RevisionText("I saw a cat, then left.")
        revision.wrap(2...3, in: .bold)
        XCTAssertEqual(revision.revisedText, "I saw **a cat**, then left.")

        var sentence = RevisionText("One. Two three.")
        sentence.wrap(1...2, in: .italic)
        XCTAssertEqual(sentence.revisedText, "One. *Two three.*")
    }

    func testCleaningTakesOutMarksAndCapitals() {
        var revision = RevisionText("I went. To the store. And bought milk.")
        let ids = revision.tokens.map(\.id)
        let left = revision.clean(0...7)
        XCTAssertEqual(revision.revisedText, "I went to the store and bought milk.")
        XCTAssertEqual(left, ids)
    }

    func testCleaningMidSentenceLowersTheFirstWord() {
        var revision = RevisionText("We left. Early, “Before dawn.” Then rain.")
        revision.clean(1...4)
        XCTAssertEqual(revision.revisedText, "We left early before dawn. Then rain.")
    }

    func testCleaningKeepsWhatsInsideWords() {
        var revision = RevisionText("Don't. Well-known, NASA said 3.5% Then.")
        revision.clean(0...5)
        XCTAssertEqual(revision.revisedText, "Don't well-known NASA said 3.5% then.")
    }

    func testCleaningDropsAWordThatWasOnlyMarks() {
        var revision = RevisionText("A cat — a dog")
        let left = revision.clean(1...3)
        XCTAssertEqual(revision.revisedText, "A cat a dog")
        XCTAssertEqual(left.count, 2)
    }
}
