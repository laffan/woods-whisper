import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import WoodsWhisperKit

final class WoodsWhisperKitTests: XCTestCase {

    func testPresetRendersWithToken() {
        let preset = PromptPreset(name: "X", template: "Do it:\n\n\(PromptPreset.transcriptToken)")
        XCTAssertEqual(preset.render(with: "hello"), "Do it:\n\nhello")
    }

    func testPresetAppendsWhenTokenAbsent() {
        let preset = PromptPreset(name: "X", template: "Do it.")
        XCTAssertEqual(preset.render(with: "hello"), "Do it.\n\nhello")
    }

    func testBuiltInPresetsArePresent() {
        XCTAssertFalse(PromptPreset.builtIns.isEmpty)
        XCTAssertTrue(PromptPreset.builtIns.allSatisfy { $0.isBuiltIn })
    }

    func testRecordingDefaultNameNotEmpty() {
        let r = Recording(audioFileName: "x.m4a", origin: .watch)
        XCTAssertFalse(r.name.isEmpty)
        XCTAssertEqual(r.sampleRate, 16_000)
    }

    func testDefaultNameIsTwoLinesWithLengthAndSize() {
        let name = Recording.defaultName(for: Date(), duration: 7, byteCount: 28_672)
        let lines = name.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 2)                      // [Date, Time] / [Length - Size]
        XCTAssertTrue(lines[1].contains("0:07"))           // length as m:ss
        XCTAssertTrue(lines[1].contains(" - "))            // length - size separator
        XCTAssertTrue(lines[1].contains("KB"))             // byte size present
    }

    func testDefaultNameOmitsSizeWhenUnknown() {
        let name = Recording.defaultName(for: Date(), duration: 65, byteCount: nil)
        let lines = name.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(lines[1]), "1:05")           // length only, no size
    }

    func testDurationLabelFormatsMinutesSeconds() {
        XCTAssertEqual(Recording.durationLabel(0), "0:00")
        XCTAssertEqual(Recording.durationLabel(9), "0:09")
        XCTAssertEqual(Recording.durationLabel(75), "1:15")
    }

    func testRecordingTransferRoundTrips() throws {
        let rec = Recording(audioFileName: "x.m4a", origin: .pad)
        let transfer = RecordingTransfer(recording: rec, byteCount: 123, pairingSecret: "s")
        let data = try JSONEncoder.iso.encode(transfer)
        let decoded = try JSONDecoder.iso.decode(RecordingTransfer.self, from: data)
        XCTAssertEqual(decoded.recording.id, rec.id)
        XCTAssertEqual(decoded.byteCount, 123)
        XCTAssertEqual(decoded.pairingSecret, "s")
    }

    /// Where a clip's words are owed rides on the clip itself, so a capture made while the speech
    /// model is still downloading still knows where to land once it's transcribed — days and a
    /// relaunch later, if that's how it goes.
    func testBodyDestinationRoundTrips() throws {
        for destination in [Recording.BodyDestination.append, .at(3)] {
            let rec = Recording(audioFileName: "x.m4a", origin: .phone, bodyDestination: destination)
            let decoded = try JSONDecoder.iso.decode(Recording.self,
                                                     from: JSONEncoder.iso.encode(rec))
            XCTAssertEqual(decoded.bodyDestination, destination)
        }
    }

    /// A clip with no body to reach — an Inbox capture, a graph node's, anything saved by a build
    /// from before the key existed — decodes as owing nothing.
    func testRecordingWithoutABodyDestinationOwesNothing() throws {
        XCTAssertNil(Recording(audioFileName: "x.m4a", origin: .watch).bodyDestination)
        let json = """
        {"id":"\(UUID().uuidString)","name":"Clip","createdAt":"2026-07-31T14:30:05Z",\
        "duration":3,"audioFileName":"x.m4a","sampleRate":16000,"origin":"watch","status":"pending"}
        """
        let decoded = try JSONDecoder.iso.decode(Recording.self, from: Data(json.utf8))
        XCTAssertNil(decoded.bodyDestination)
        XCTAssertFalse(decoded.isRevision)
    }

    func testLanguageModelDefaultIsTheSmallLFM() {
        XCTAssertEqual(LanguageModelChoice.default, .lfm2_5_1_2B)
        XCTAssertFalse(LanguageModelChoice.default.isOnline)
    }

    /// On-device there's one model: LFM2.5 1.2B Instruct, by the MLX repo the download actually
    /// asks HuggingFace for.
    func testOnDeviceLineupIsTheSmallLFM() {
        let local = LanguageModelChoice.allCases.filter { !$0.isOnline }
        XCTAssertEqual(local, [.lfm2_5_1_2B])
        XCTAssertTrue(local.allSatisfy { $0.rawValue.contains("LFM2.5") })
        XCTAssertTrue(local.allSatisfy { $0.rawValue.contains("MLX-4bit") })
    }

    /// The models that used to be here are listed by repo so their weights can be deleted — none of
    /// them may still be in the picker, or the cleanup would delete a model you can select.
    func testRetiredReposAreNoLongerSelectable() {
        let ids = Set(LanguageModelChoice.allCases.map(\.rawValue))
        XCTAssertFalse(LanguageModelChoice.retiredRepos.isEmpty)
        XCTAssertTrue(LanguageModelChoice.retiredRepos.allSatisfy { !ids.contains($0) })
    }

    func testEveryOnDeviceModelHasStopSequences() {
        // Local models need explicit turn-end markers; online ones let the API signal end-of-turn.
        let local = LanguageModelChoice.allCases.filter { !$0.isOnline }
        XCTAssertTrue(local.allSatisfy { $0.stopSequences.contains("<|im_end|>") })
        XCTAssertTrue(LanguageModelChoice.claudeSonnet.stopSequences.isEmpty)
    }

    /// Nothing in the lineup reasons any more — the one that did was too slow on a phone to keep —
    /// so no transform should be splitting a `<think>` block out of anything. (`ThinkSplitter`
    /// itself is still tested below: the guarantee has to hold the day a reasoning model returns.)
    func testNoModelInTheLineupThinks() {
        XCTAssertTrue(LanguageModelChoice.allCases.allSatisfy { !$0.usesThinkTags })
        XCTAssertTrue(LanguageModelChoice.allCases.allSatisfy { !$0.opensThinkBlockInTemplate })
    }

    func testOnlyClaudeModelsAreOnline() {
        XCTAssertTrue(LanguageModelChoice.claudeSonnet.isOnline)
        XCTAssertTrue(LanguageModelChoice.claudeHaiku.isOnline)
        XCTAssertFalse(LanguageModelChoice.lfm2_5_1_2B.isOnline)
    }

    func testOnlineModelsUseApiModelIDAsRawValue() {
        XCTAssertEqual(LanguageModelChoice.claudeSonnet.rawValue, "claude-sonnet-4-6")
        XCTAssertEqual(LanguageModelChoice.claudeHaiku.rawValue, "claude-haiku-4-5")
    }

    func testShortNamesAreConcise() {
        XCTAssertEqual(LanguageModelChoice.claudeHaiku.shortName, "Haiku 4.5")
        XCTAssertEqual(LanguageModelChoice.lfm2_5_1_2B.shortName, "LFM2.5 1.2B")
    }

    // MARK: Streaming filters (reasoning never reaches the text)

    /// Feed a whole response through the splitter the way the model streams it — in pieces, split
    /// wherever the caller says, including through the middle of a tag.
    private func split(_ chunks: [String], enabled: Bool = true,
                       startsInside: Bool = false) -> (reasoning: String, answer: String) {
        var splitter = ThinkSplitter(enabled: enabled, startsInside: startsInside)
        var reasoning = ""
        var answer = ""
        for chunk in chunks {
            let parts = splitter.consume(chunk)
            reasoning += parts.reasoning
            answer += parts.answer
        }
        let last = splitter.flush()
        return (reasoning + last.reasoning, answer + last.answer)
    }

    /// The one guarantee the reasoning models rest on: what gets saved is the answer, and not a
    /// character of the thinking — nor either tag.
    func testReasoningNeverReachesTheAnswer() {
        let out = split(["<think>The user wants this tidied up.</think>", "Elk by the creek."])
        XCTAssertEqual(out.answer, "Elk by the creek.")
        XCTAssertEqual(out.reasoning, "The user wants this tidied up.")
        XCTAssertFalse(out.answer.contains("think"))
        XCTAssertFalse(out.answer.contains("<"))
    }

    /// Tags arrive split across chunks — a token boundary lands mid-tag sooner or later — and the
    /// halves must not leak into the answer while the splitter waits for the rest.
    func testTagsSplitAcrossChunksStillSeparateCleanly() {
        let out = split(["<th", "ink>weigh", "ing it up</thi", "nk>", "Elk ", "by the creek."])
        XCTAssertEqual(out.answer, "Elk by the creek.")
        XCTAssertEqual(out.reasoning, "weighing it up")
    }

    /// LFM2.5-2.6B: the chat template opens the block, so the stream starts inside it and only the
    /// closing tag ever arrives. Everything before it is thinking, whatever it looks like.
    func testATemplateOpenedBlockIsReasoningFromTheFirstToken() {
        let out = split(["Let me think about this.", "</think>", "Elk by the creek."],
                        startsInside: true)
        XCTAssertEqual(out.answer, "Elk by the creek.")
        XCTAssertEqual(out.reasoning, "Let me think about this.")
    }

    /// A block that never closes — the model was still thinking when it hit the token cap — is
    /// reasoning to the last character, whoever opened it. There is simply no answer, which is the
    /// safe outcome: a transform with nothing to say leaves your text alone rather than replacing it
    /// with half a thought.
    func testAnUnterminatedBlockIsAllReasoningAndLeavesNoAnswer() {
        let templateOpened = split(["Let me weigh this up", " and up"], startsInside: true)
        XCTAssertTrue(templateOpened.answer.isEmpty)
        XCTAssertEqual(templateOpened.reasoning, "Let me weigh this up and up")

        let modelOpened = split(["<think>still going"])
        XCTAssertTrue(modelOpened.answer.isEmpty)
        XCTAssertEqual(modelOpened.reasoning, "still going")
    }

    func testANonThinkingModelPassesEverythingThroughAsTheAnswer() {
        let out = split(["Elk ", "by the creek."], enabled: false)
        XCTAssertEqual(out.answer, "Elk by the creek.")
        XCTAssertTrue(out.reasoning.isEmpty)
    }

    /// The turn-end marker halts the stream and never appears in the text — including when it
    /// arrives a character at a time.
    func testStopSequenceHaltsTheStreamAndIsNotEmitted() {
        var filter = StopSequenceFilter(stops: ["<|im_end|>"])
        var out = ""
        for chunk in ["Elk by the creek.", "<|im", "_end|>", "and more"] {
            out += filter.consume(chunk)
        }
        out += filter.flush()
        XCTAssertEqual(out, "Elk by the creek.")
        XCTAssertTrue(filter.isStopped)
    }

    /// A partial marker that turns out to be ordinary text is emitted, not swallowed.
    func testHeldBackTextIsEmittedWhenItIsNotAStopSequence() {
        var filter = StopSequenceFilter(stops: ["<|im_end|>"])
        var out = filter.consume("2 < 3 and 4 <")
        out += filter.flush()
        XCTAssertEqual(out, "2 < 3 and 4 <")
        XCTAssertFalse(filter.isStopped)
    }

    // MARK: Markdown backup mirror

    /// The Inbox container's title, as a plain constant so these tests don't have to hop to the
    /// main actor for `DocumentStore.inboxTitle` (pinned to it by `testInboxTitleIsInbox`).
    private let inboxTitle = "Inbox"

    /// A fixed local date, so the timestamp-derived file names are predictable wherever the tests run
    /// (both the calendar and the naming formatter use the current time zone).
    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var components = DateComponents()
        (components.year, components.month, components.day) = (year, month, day)
        (components.hour, components.minute, components.second) = (hour, minute, second)
        return Calendar.current.date(from: components)!
    }

    @MainActor
    func testInboxTitleIsInbox() {
        XCTAssertEqual(DocumentStore.inboxTitle, inboxTitle)
    }

    // MARK: Paragraph splitting

    /// Typed text keeps the blank-line rule: a soft break stays inside its paragraph.
    func testTypedTextSplitsOnBlankLinesOnly() {
        let split = Document.paragraphs(from: "First line\nsecond line\n\nSecond block")
        XCTAssertEqual(split.map(\.text), ["First line\nsecond line", "Second block"])
    }

    /// A transcript a transform gave line breaks to arrives as one paragraph per line — each with
    /// its own inter-paragraph "+" once it is in a document.
    func testTranscriptSplitsOnEveryLineBreak() {
        let split = Document.paragraphs(fromLinesOf: "- Firewood\n- Water\n- Map")
        XCTAssertEqual(split.map(\.text), ["- Firewood", "- Water", "- Map"])
    }

    /// Blank lines, trailing whitespace and Windows line endings don't leave empty paragraphs behind.
    func testTranscriptSplittingDropsBlanksAndTrimsLines() {
        let split = Document.paragraphs(fromLinesOf: "  One  \r\n\r\n\nTwo\n   \n")
        XCTAssertEqual(split.map(\.text), ["One", "Two"])
    }

    /// An unbroken transcript — what a spoken clip normally comes back as — stays a single paragraph.
    func testAnUnbrokenTranscriptStaysOneParagraph() {
        let split = Document.paragraphs(fromLinesOf: "Elk by the creek at first light.")
        XCTAssertEqual(split.map(\.text), ["Elk by the creek at first light."])
    }

    func testSplittingNothingYieldsNoParagraphs() {
        XCTAssertTrue(Document.paragraphs(fromLinesOf: "   \n\n ").isEmpty)
    }

    // MARK: Joint documents, made

    func testSearchIgnoresCaseAndAccentsAndReachesEveryText() {
        var doc = Document(title: "Trail notes")
        doc.paragraphs = [Document.Paragraph(text: "We passed the Café by the river.")]
        doc.recordings = [Recording(audioFileName: "a.m4a", origin: .phone, transcript: "Owl at dusk")]
        XCTAssertTrue(doc.matches("cafe"))
        XCTAssertTrue(doc.matches("TRAIL"))
        XCTAssertTrue(doc.matches("owl"))
        XCTAssertTrue(doc.matches("  "))                 // an empty query matches everything
        XCTAssertFalse(doc.matches("heron"))
    }

    func testSearchExcerptSurroundsTheMatch() {
        var doc = Document(title: "Notes")
        doc.paragraphs = [Document.Paragraph(text: String(repeating: "a ", count: 40) + "needle here")]
        let excerpt = doc.searchExcerpt(for: "needle", radius: 6)
        XCTAssertEqual(excerpt, "…a a a needle here")
        XCTAssertNil(doc.searchExcerpt(for: "Notes"))     // the title alone isn't an excerpt
    }

    func testMergingAppendsWithASingleSpace() {
        XCTAssertEqual(Document.merging("  second part. ", into: "First part."),
                       "First part. second part.")
    }

    func testMergingInsertsAtAWordBoundary() {
        // Offset 6 is the start of "brown".
        XCTAssertEqual(Document.merging("quick", into: "A big brown fox", at: 6),
                       "A big quick brown fox")
        XCTAssertEqual(Document.merging("Hey.", into: "there", at: 0), "Hey. there")
        XCTAssertEqual(Document.merging("end", into: "start", at: 99), "start end")
    }

    // MARK: Continuing a recording

    func testAContinuationFindsEverySectionTheRecordingBecame() {
        let rec = Recording(audioFileName: "a.m4a", origin: .phone, transcript: "First.\nSecond.",
                            status: .done)
        let typed = Document.Paragraph(text: "Typed by hand.")
        let mine = Document.paragraphs(fromLinesOf: rec.transcript!, recordingID: rec.id)
        let doc = Document(title: "D", paragraphs: [mine[0], typed, mine[1]], recordings: [rec])

        let found = doc.continuation(forParagraph: mine[1].id)
        XCTAssertEqual(found?.recording.id, rec.id)
        XCTAssertEqual(found?.sections, [mine[0].id, mine[1].id])
        XCTAssertNil(doc.continuation(forParagraph: typed.id))
    }

    func testAnOlderSectionIsMatchedToItsRecordingByItsWords() {
        // Saved before sections remembered their recording: found by what they say.
        let rec = Recording(audioFileName: "a.m4a", origin: .phone,
                            transcript: "The trail forks here.\nTake the left one.", status: .done)
        let first = Document.Paragraph(text: "The trail forks  here.")
        let second = Document.Paragraph(text: "take the left one.")
        let other = Document.Paragraph(text: "Something else entirely.")
        let doc = Document(title: "D", paragraphs: [first, other, second], recordings: [rec])

        let found = doc.continuation(forParagraph: second.id)
        XCTAssertEqual(found?.recording.id, rec.id)
        XCTAssertEqual(found?.sections, [first.id, second.id])
        XCTAssertNil(doc.continuation(forParagraph: other.id))
    }

    func testTextWithNoAudioHasNothingToContinue() {
        let entry = Recording.textEntry("Imported words.", origin: .phone)
        let para = Document.Paragraph(text: "Imported words.", recordingID: entry.id)
        let doc = Document(title: "D", paragraphs: [para], recordings: [entry])
        XCTAssertNil(doc.continuation(forParagraph: para.id))
    }

    func testOlderSectionsDecodeWithoutARecording() throws {
        let json = #"{"id":"\#(UUID().uuidString)","text":"Old."}"#
        let para = try JSONDecoder().decode(Document.Paragraph.self, from: Data(json.utf8))
        XCTAssertEqual(para.text, "Old.")
        XCTAssertNil(para.recordingID)
    }

    @MainActor
    func testReplacingSectionsPutsTheWordsWhereTheRunStarted() {
        let name = "ReplaceRunTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let doc = store.createDocument(title: "Notes")
        let a = Document.Paragraph(text: "A"), b = Document.Paragraph(text: "B")
        let c = Document.Paragraph(text: "C"), d = Document.Paragraph(text: "D")
        store.setParagraphs([a, b, c, d], in: doc.id)

        store.replaceParagraphs([d.id, b.id], in: doc.id,
                                with: [Document.Paragraph(text: "X"), Document.Paragraph(text: "Y")])
        XCTAssertEqual(store.document(with: doc.id)?.paragraphs.map(\.text), ["A", "X", "Y", "C"])

        // Nothing of the run left: the words still belong in the document, on the end.
        store.replaceParagraphs([UUID()], in: doc.id, with: [Document.Paragraph(text: "Z")])
        XCTAssertEqual(store.document(with: doc.id)?.paragraphs.map(\.text), ["A", "X", "Y", "C", "Z"])
    }

    @MainActor
    func testEditingASectionKeepsTheRecordingItCameFrom() {
        let name = "EditKeepsSourceTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let recordingID = UUID()
        let doc = store.createDocument(title: "Notes")
        let para = Document.Paragraph(text: "Spoken.", recordingID: recordingID)
        store.setParagraphs([para], in: doc.id)

        store.replaceParagraph(para.id, in: doc.id, withTextSplitInto: "Spoken, edited.\n\nAnd split.")
        let after = store.document(with: doc.id)?.paragraphs ?? []
        XCTAssertEqual(after.map(\.text), ["Spoken, edited.", "And split."])
        XCTAssertEqual(after.map(\.recordingID), [recordingID, recordingID])
    }

    @MainActor
    func testContinuingARecordingMakesTheNextTranscriptionAFirstOne() {
        let name = "ContinueTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let doc = store.createDocument(title: "Notes")
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let rec = Recording(name: Recording.defaultName(for: created, duration: 5, byteCount: nil),
                            createdAt: created, duration: 5, audioFileName: "old.m4a",
                            origin: .phone, transcript: "Hello.", status: .done, tag: "Fix")
        store.addRecording(rec, toDocument: doc.id)
        let section = UUID()

        store.continueRecording(rec.id, in: doc.id, newFileName: "new.m4a", duration: 12,
                                replacingSections: [section])
        let after = store.document(with: doc.id)?.recordings.first
        XCTAssertEqual(after?.audioFileName, "new.m4a")
        XCTAssertEqual(after?.duration, 12)
        XCTAssertNil(after?.transcript)            // nil is what makes the Auto transform run again
        XCTAssertEqual(after?.status, .pending)
        XCTAssertEqual(after?.bodyDestination, .replacingSections([section]))
        XCTAssertEqual(after?.tag, "Fix")
        XCTAssertTrue(after?.name.contains("0:12") ?? false)   // a default name follows the length
    }

    func testADefaultNameIsToldApartFromAChosenOne() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(Recording.isDefaultName(Recording.defaultName(for: created, duration: 3,
                                                                    byteCount: 1_000),
                                              createdAt: created))
        XCTAssertFalse(Recording.isDefaultName("Trailhead notes", createdAt: created))
    }

    #if canImport(AVFoundation)
    func testJoiningTwoClipsMakesOneAsLongAsBoth() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JoinTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func tone(_ seconds: Double, rate: Double, named name: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                                           AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(seconds * rate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                        frameCapacity: frames))
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / rate)) * 0.3
            }
            try file.write(from: buffer)
            return url
        }
        let first = try tone(1.0, rate: 16_000, named: "a.m4a")
        let second = try tone(0.5, rate: 44_100, named: "b.m4a")     // converted on the way in
        let joined = dir.appendingPathComponent("joined.m4a")

        let duration = try AudioJoiner.join([first, second], into: joined)
        XCTAssertEqual(duration, 1.5, accuracy: 0.15)
        let readBack = try AVAudioFile(forReading: joined)
        XCTAssertEqual(readBack.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(Double(readBack.length) / 16_000, 1.5, accuracy: 0.15)
    }
    #endif

    // MARK: Sharing between devices

    @MainActor
    func testASharedDocumentKeepsItsIDAndIsRecognisedOnTheWayBack() throws {
        let phoneName = "PhoneTests-\(UUID().uuidString)"
        let padName = "PadTests-\(UUID().uuidString)"
        let phone = DocumentStore(directoryName: phoneName)
        let pad = DocumentStore(directoryName: padName)
        defer { removeStore(named: phoneName); removeStore(named: padName) }

        let doc = phone.createDocument(title: "Field Notes")
        phone.setParagraphs([Document.Paragraph(text: "Started on the phone.")], in: doc.id)
        phone.setPinned(true, for: doc.id)

        // Phone → iPad: new there, under the same id.
        let toPad = try pad.readArchive(from: phone.exportArchive(for: doc.id))
        XCTAssertNil(pad.existingDocument(matching: toPad.document))
        let onPad = pad.importArchive(toPad, replacing: nil)
        XCTAssertEqual(onPad.id, doc.id)
        pad.setParagraphs([Document.Paragraph(text: "Started on the phone."),
                           Document.Paragraph(text: "Carried on on the iPad.")], in: onPad.id)

        // iPad → phone: recognised, and replaced in place — id and pin kept.
        let back = try phone.readArchive(from: pad.exportArchive(for: onPad.id))
        XCTAssertEqual(phone.existingDocument(matching: back.document)?.id, doc.id)
        phone.importArchive(back, replacing: doc.id)
        XCTAssertEqual(phone.documents.filter { $0.title == "Field Notes" }.count, 1)
        let replaced = try XCTUnwrap(phone.document(with: doc.id))
        XCTAssertEqual(replaced.paragraphs.map(\.text),
                       ["Started on the phone.", "Carried on on the iPad."])
        XCTAssertTrue(replaced.isPinned)
    }

    @MainActor
    func testASameNamedDocumentIsOfferedForReplacementAndKeepBothMakesACopy() throws {
        let name = "SameNameTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let mine = store.createDocument(title: "Trip Log")
        let arriving = Document(title: "  trip log ", paragraphs: [Document.Paragraph(text: "Elsewhere.")])
        XCTAssertEqual(store.existingDocument(matching: arriving)?.id, mine.id)
        // A graph of the same name is a different thing (the other half of a joint document has
        // the same title as the first).
        XCTAssertNil(store.existingDocument(matching: Document(title: "Trip Log", kind: .graph)))

        let copy = store.importArchive(DocumentArchive(document: arriving, audio: [:]), replacing: nil)
        XCTAssertNotEqual(copy.id, mine.id)
        XCTAssertEqual(store.documents.count, 2)

        // Its own id is taken here, so a second "keep both" can't alias the first copy.
        let again = store.importArchive(DocumentArchive(document: copy, audio: [:]), replacing: nil)
        XCTAssertNotEqual(again.id, copy.id)
    }

    @MainActor
    func testReplacingBringsTheRecordingsAndTheirAudio() throws {
        let fromName = "AudioFromTests-\(UUID().uuidString)"
        let toName = "AudioToTests-\(UUID().uuidString)"
        let from = DocumentStore(directoryName: fromName)
        let to = DocumentStore(directoryName: toName)
        defer { removeStore(named: fromName); removeStore(named: toName) }

        let source = from.createDocument(title: "Walk")
        let clip = Recording(audioFileName: "clip.m4a", origin: .pad, transcript: "Hi.", status: .done)
        from.addRecording(clip, audioData: Data([1, 2, 3]), toDocument: source.id)

        let local = to.createDocument(title: "Walk")
        let stale = Recording(audioFileName: "stale.m4a", origin: .phone)
        to.addRecording(stale, audioData: Data([9]), toDocument: local.id)
        let staleURL = to.audioURL(for: stale)

        let archive = try to.readArchive(from: from.exportArchive(for: source.id))
        to.importArchive(archive, replacing: local.id)
        let after = try XCTUnwrap(to.document(with: local.id))
        XCTAssertEqual(after.recordings.map(\.id), [clip.id])
        let arrived = try XCTUnwrap(after.recordings.first)
        XCTAssertNotEqual(arrived.audioFileName, "clip.m4a")            // a fresh file name
        XCTAssertEqual(try Data(contentsOf: to.audioURL(for: arrived)), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
    }

    @MainActor
    func testAJointDocumentTravelsAsAPair() throws {
        let fromName = "JointFromTests-\(UUID().uuidString)"
        let toName = "JointToTests-\(UUID().uuidString)"
        let from = DocumentStore(directoryName: fromName)
        let to = DocumentStore(directoryName: toName)
        defer { removeStore(named: fromName); removeStore(named: toName) }

        let prose = from.createDocument(title: "Plan")
        let graph = try XCTUnwrap(from.createJointCounterpart(for: prose.id))
        let archive = try to.readArchive(from: from.exportArchive(for: graph.id))
        XCTAssertEqual(archive.partner?.id, prose.id)

        let arrived = to.importArchive(archive, replacing: nil)
        XCTAssertEqual(to.jointPartnerID(of: arrived.id), prose.id)
        XCTAssertEqual(to.document(with: prose.id)?.joinedID, graph.id)    // the link where it was

        // Sent again and replaced: still one pair, not a pair with an extra half.
        let again = try to.readArchive(from: from.exportArchive(for: prose.id))
        to.importArchive(again, replacing: prose.id)
        XCTAssertEqual(to.documents.count, 2)
        XCTAssertEqual(to.jointPartnerID(of: prose.id), graph.id)
    }

    @MainActor
    func testMergingAParagraphRemovesTheDraggedOne() {
        let name = "MergeTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let doc = store.createDocument(title: "Notes")
        let a = Document.Paragraph(text: "One two.")
        let b = Document.Paragraph(text: "Three.")
        let c = Document.Paragraph(text: "Four.")
        store.setParagraphs([a, b, c], in: doc.id)

        store.mergeParagraph(c.id, into: a.id, in: doc.id)
        XCTAssertEqual(store.document(with: doc.id)?.paragraphs.map(\.text), ["One two. Four.", "Three."])

        store.mergeParagraph(b.id, into: a.id, at: 4, in: doc.id)
        XCTAssertEqual(store.document(with: doc.id)?.paragraphs.map(\.text), ["One Three. two. Four."])
    }

    @MainActor
    func testMovingAParagraphAppendsItToTheOtherDocument() {
        let name = "MoveParagraphTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let source = store.createDocument(title: "Source")
        let target = store.createDocument(title: "Target")
        let keep = Document.Paragraph(text: "Stays.")
        let go = Document.Paragraph(text: "Goes.")
        store.setParagraphs([keep, go], in: source.id)
        store.setParagraphs([Document.Paragraph(text: "Already here.")], in: target.id)

        store.moveParagraph(go.id, from: source.id, to: target.id)
        XCTAssertEqual(store.document(with: source.id)?.paragraphs.map(\.id), [keep.id])
        XCTAssertEqual(store.document(with: target.id)?.paragraphs.map(\.text), ["Already here.", "Goes."])
        XCTAssertEqual(store.document(with: target.id)?.paragraphs.last?.id, go.id)
    }

    @MainActor
    func testFilingInboxEntriesWritesTheirTranscriptsIntoTheBody() {
        let name = "FileRecordingsTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let inbox = store.createDocument(title: "Inbox Source")
        let target = store.createDocument(title: "Target")
        store.setParagraphs([Document.Paragraph(text: "Already here.")], in: target.id)
        let older = Recording(createdAt: Date(timeIntervalSince1970: 100), audioFileName: "a.m4a",
                              origin: .phone, transcript: "First line\nSecond line", status: .done)
        let newer = Recording(createdAt: Date(timeIntervalSince1970: 200), audioFileName: "b.m4a",
                              origin: .phone, transcript: "Third", status: .done)
        let pending = Recording(createdAt: Date(timeIntervalSince1970: 300), audioFileName: "c.m4a",
                                origin: .phone)
        for recording in [newer, older, pending] { store.addRecording(recording, toDocument: inbox.id) }

        store.fileRecordings([older.id, newer.id, pending.id], from: inbox.id, into: target.id)

        let filed = store.document(with: target.id)
        XCTAssertEqual(filed?.paragraphs.map(\.text),
                       ["Already here.", "First line", "Second line", "Third"])
        XCTAssertEqual(filed?.recordings.count, 3)
        XCTAssertEqual(filed?.recordings.first { $0.id == pending.id }?.bodyDestination, .append)
        XCTAssertNil(filed?.recordings.first { $0.id == older.id }?.bodyDestination)
        XCTAssertTrue(store.document(with: inbox.id)?.recordings.isEmpty ?? false)
    }

    /// The link has to land on the document that asked for it. It used to land on whichever
    /// document sat above it in the array: the index was taken before the counterpart was inserted
    /// at the front, and the insert moved everything down a place.
    @MainActor
    func testCreatingAJointCounterpartLinksTheDocumentThatAskedForIt() {
        let name = "JointTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        // The graph goes in first so that the *other* document ends up above it — which is the
        // stranger the link used to be written onto.
        let graph = store.createDocument(title: "Field Notes", kind: .graph)
        let stranger = store.createDocument(title: "Trip Log")

        let counterpart = store.createJointCounterpart(for: graph.id)

        XCTAssertNotNil(counterpart)
        XCTAssertEqual(counterpart?.isGraph, false)                      // a graph gets prose
        XCTAssertEqual(store.jointPartnerID(of: graph.id), counterpart?.id)
        XCTAssertEqual(store.document(with: graph.id)?.joinedID, counterpart?.id)
        XCTAssertNil(store.document(with: stranger.id)?.joinedID)
        XCTAssertNil(store.document(with: counterpart!.id)?.joinedID)
        XCTAssertTrue(store.isJointFollower(counterpart!.id))
    }

    @MainActor
    func testADocumentGetsAGraphAndOnlyOne() {
        let name = "JointTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let notes = store.createDocument(title: "Field Notes")
        let graph = store.createJointCounterpart(for: notes.id)
        XCTAssertEqual(graph?.isGraph, true)
        // Asking twice does nothing: it's already half of a pair.
        XCTAssertNil(store.createJointCounterpart(for: notes.id))
        XCTAssertNil(store.createJointCounterpart(for: graph!.id))
    }

    /// Two documents of the same kind is not a pair, and a build that wrote one is repaired on the
    /// next load rather than left opening onto "Joint document not found".
    @MainActor
    func testAnImpossibleJointIsDroppedOnLoad() throws {
        let name = "JointTests-\(UUID().uuidString)"
        let follower = Document(title: "Trip Log")
        let lead = Document(title: "Field Notes", joinedID: follower.id)   // document → document
        try writeDocuments([lead, follower], toStoreNamed: name)
        defer { removeStore(named: name) }

        let store = DocumentStore(directoryName: name)

        XCTAssertEqual(store.documents.count, 2, "the fixture didn't load — has the layout moved?")
        XCTAssertNil(store.document(with: lead.id)?.joinedID)
        XCTAssertNil(store.jointPartnerID(of: lead.id))
    }

    private func storeDirectory(named name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    private func writeDocuments(_ documents: [Document], toStoreNamed name: String) throws {
        let directory = storeDirectory(named: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(documents)
            .write(to: directory.appendingPathComponent("documents.json"))
    }

    private func removeStore(named name: String) {
        try? FileManager.default.removeItem(at: storeDirectory(named: name))
    }

    // MARK: Inbox tags

    func testTheFirstWordFilesTheEntry() {
        XCTAssertEqual(InboxTag.autoTag(for: "Question — where does the trail cross?",
                                        from: InboxTag.defaultNames), "Question")
    }

    /// "How it was said" shouldn't decide whether it files: same word, same tag.
    func testVersionsOfTheWordStillFile() {
        XCTAssertEqual(InboxTag.autoTag(for: "Questions about the pass", from: InboxTag.defaultNames),
                       "Question")
        XCTAssertEqual(InboxTag.autoTag(for: "Fixed the stove", from: InboxTag.defaultNames), "Fix")
        XCTAssertEqual(InboxTag.autoTag(for: "Fixing the stove", from: InboxTag.defaultNames), "Fix")
        XCTAssertEqual(InboxTag.autoTag(for: "Reminders: water filter", from: InboxTag.defaultNames),
                       "Reminder")
        XCTAssertEqual(InboxTag.autoTag(for: "remind me to soak the beans",
                                        from: InboxTag.defaultNames), "Reminder")
    }

    /// The word has to *start* the entry — a tag mentioned later is just a word in a sentence.
    func testATagInTheMiddleDoesNotFile() {
        XCTAssertNil(InboxTag.autoTag(for: "I have a question about the pass",
                                      from: InboxTag.defaultNames))
    }

    func testOrdinaryTextFilesNowhere() {
        XCTAssertNil(InboxTag.autoTag(for: "Elk by the creek at first light",
                                      from: InboxTag.defaultNames))
        XCTAssertNil(InboxTag.autoTag(for: "", from: InboxTag.defaultNames))
        XCTAssertNil(InboxTag.autoTag(for: "   ", from: InboxTag.defaultNames))
    }

    /// A short tag isn't stemmed away to nothing, and doesn't swallow longer words.
    func testShortTagsSurviveStemming() {
        XCTAssertTrue(InboxTag.matches("Fix:", tag: "Fix"))
        XCTAssertFalse(InboxTag.matches("Fixture", tag: "Fix"))
    }

    /// Ties go to the order the list is in, which is the order Settings shows.
    func testTheEarlierTagWins() {
        XCTAssertEqual(InboxTag.autoTag(for: "Fix that", from: ["Fix", "Fixes"]), "Fix")
        XCTAssertEqual(InboxTag.autoTag(for: "Fix that", from: ["Fixes", "Fix"]), "Fixes")
    }

    /// The three you start with are three different colours — the point of colouring them at all.
    func testTheDefaultTagsAreDifferentColours() {
        let colors = InboxTag.defaultStyles.map(\.colorID)
        XCTAssertEqual(Set(colors).count, colors.count)
        XCTAssertTrue(colors.allSatisfy(InboxTag.paletteIDs.contains))
    }

    /// A tag being added takes the first colour nothing else is wearing.
    func testANewTagTakesAnUnusedColour() {
        let used = InboxTag.defaultStyles.map(\.colorID)
        let next = InboxTag.nextColorID(notIn: used)
        XCTAssertFalse(used.contains(next))
        XCTAssertTrue(InboxTag.paletteIDs.contains(next))
    }

    /// With every colour taken it starts round again rather than coming back with nothing.
    func testColoursRunOutGracefully() {
        let next = InboxTag.nextColorID(notIn: InboxTag.paletteIDs)
        XCTAssertTrue(InboxTag.paletteIDs.contains(next))
    }

    func testATagSurvivesARecordingRoundTrip() throws {
        let clip = Recording(audioFileName: "a.m4a", origin: .phone, tag: "Reminder")
        let decoded = try JSONDecoder.iso.decode(Recording.self,
                                                 from: try JSONEncoder.iso.encode(clip))
        XCTAssertEqual(decoded.tag, "Reminder")
    }

    /// A recording saved before tags existed reads back untagged.
    func testRecordingWithoutATagKeyDecodesAsUntagged() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Clip","createdAt":"2026-07-31T14:30:05Z",\
        "duration":3,"audioFileName":"a.m4a","sampleRate":16000,"origin":"phone","status":"done"}
        """
        let decoded = try JSONDecoder.iso.decode(Recording.self, from: Data(json.utf8))
        XCTAssertNil(decoded.tag)
    }

    // MARK: Joint documents

    /// A link between two of a kind isn't a pair, so it hides nothing — the state an early build
    /// could leave behind, harmless until it's cleared.
    func testALinkBetweenTwoOfAKindHidesNothing() {
        let other = Document(title: "Trip Log")
        let notes = Document(title: "Field Notes", joinedID: other.id)
        XCTAssertTrue(Document.jointFollowerIDs(in: [notes, other]).isEmpty)
    }

    func testALinkToSomethingMissingHidesNothing() {
        let notes = Document(title: "Field Notes", joinedID: UUID())
        XCTAssertTrue(Document.jointFollowerIDs(in: [notes]).isEmpty)
    }

    /// The half a link points at is the one the lists leave out; the half that points is the row.
    func testTheJoinedHalfIsTheFollower() {
        let graph = Document(title: "Field Notes", kind: .graph)
        let notes = Document(title: "Field Notes", joinedID: graph.id)
        let loose = Document(title: "Trip Log")

        let followers = Document.jointFollowerIDs(in: [notes, graph, loose])

        XCTAssertEqual(followers, [graph.id])
    }

    func testNothingIsAFollowerWithoutAJoin() {
        let a = Document(title: "Field Notes")
        let b = Document(title: "Trip Log", kind: .graph)
        XCTAssertTrue(Document.jointFollowerIDs(in: [a, b]).isEmpty)
    }

    func testTheJoinSurvivesARoundTrip() throws {
        let partner = UUID()
        let doc = Document(title: "Field Notes", joinedID: partner)
        let decoded = try JSONDecoder.iso.decode(Document.self,
                                                 from: try JSONEncoder.iso.encode(doc))
        XCTAssertEqual(decoded.joinedID, partner)
    }

    /// A document saved before joint documents existed reads back as a document on its own.
    func testDocumentWithoutAJoinKeyDecodesAsUnjoined() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Field Notes",\
        "createdAt":"2026-07-31T14:30:05Z","updatedAt":"2026-07-31T14:30:05Z"}
        """
        let decoded = try JSONDecoder.iso.decode(Document.self, from: Data(json.utf8))
        XCTAssertNil(decoded.joinedID)
    }

    // MARK: Auto transform

    func testAutoTransformChoiceRoundTrips() throws {
        let preset = PromptPreset(name: "Clean Up", template: "Tidy this.")
        let doc = Document(title: "Field Notes", autoTransformPresetID: preset.id)
        let decoded = try JSONDecoder.iso.decode(Document.self,
                                                 from: try JSONEncoder.iso.encode(doc))
        XCTAssertEqual(decoded.autoTransformPresetID, preset.id)
    }

    /// A document saved before Auto transform existed still loads — and reads as "off".
    func testDocumentWithoutAnAutoTransformKeyDecodesAsOff() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Field Notes",\
        "createdAt":"2026-07-31T14:30:05Z","updatedAt":"2026-07-31T14:30:05Z"}
        """
        let decoded = try JSONDecoder.iso.decode(Document.self, from: Data(json.utf8))
        XCTAssertNil(decoded.autoTransformPresetID)
        XCTAssertEqual(decoded.title, "Field Notes")
    }

    func testBackupPlanSplitsInboxRecordingsFromDocuments() {
        let clip = Recording(createdAt: date(2026, 7, 31, 14, 30, 5), duration: 7,
                             audioFileName: "a.m4a", origin: .watch, transcript: "Elk by the creek.")
        let inbox = Document(title: inboxTitle, recordings: [clip])
        let notes = Document(title: "Field Notes",
                             paragraphs: [.init(text: "First."), .init(text: "Second.")])

        let plan = MarkdownBackup.plan(for: [inbox, notes], inboxTitle: inboxTitle)

        XCTAssertEqual(Set(plan.keys), ["Inbox/2026-07-31 14-30-05.md", "Documents/Field Notes.md"])
    }

    func testDocumentMarkdownIsTitleThenParagraphs() {
        let doc = Document(title: "Field Notes",
                           paragraphs: [.init(text: "First."), .init(text: "Second.")])
        XCTAssertEqual(MarkdownBackup.markdown(for: doc), "# Field Notes\n\nFirst.\n\nSecond.\n")
    }

    func testEmptyDocumentMarkdownIsJustTheTitle() {
        XCTAssertEqual(MarkdownBackup.markdown(for: Document(title: "Empty")), "# Empty\n")
    }

    func testCombinedDocumentsAreBlankLineSeparated() {
        let notes = Document(title: "Field Notes", paragraphs: [.init(text: "First.")])
        let trip = Document(title: "Trip Log", paragraphs: [.init(text: "Second.")])
        XCTAssertEqual(MarkdownBackup.combined([notes, trip]),
                       "# Field Notes\n\nFirst.\n\n# Trip Log\n\nSecond.\n")
    }

    func testCombiningOneDocumentMatchesItsOwnMarkdown() {
        let doc = Document(title: "Field Notes", paragraphs: [.init(text: "First.")])
        XCTAssertEqual(MarkdownBackup.combined([doc]), MarkdownBackup.markdown(for: doc))
    }

    func testCombinedKeepsTheHeadingOfAnEmptyDocument() {
        let empty = Document(title: "Empty")
        let notes = Document(title: "Field Notes", paragraphs: [.init(text: "First.")])
        XCTAssertEqual(MarkdownBackup.combined([empty, notes]),
                       "# Empty\n\n# Field Notes\n\nFirst.\n")
    }

    func testCombiningNothingIsEmpty() {
        XCTAssertEqual(MarkdownBackup.combined([]), "")
    }

    func testRecordingMarkdownCarriesProvenanceAndTranscript() {
        let clip = Recording(createdAt: date(2026, 7, 31, 14, 30, 5), duration: 7,
                             audioFileName: "a.m4a", origin: .watch, transcript: "Elk by the creek.")
        let markdown = MarkdownBackup.markdown(for: clip)
        XCTAssertTrue(markdown.hasPrefix("# "))                       // capture time as the heading
        XCTAssertTrue(markdown.contains("2026"))
        XCTAssertTrue(markdown.contains("*Apple Watch · 0:07*"))
        XCTAssertTrue(markdown.hasSuffix("Elk by the creek.\n"))
    }

    func testUntranscribedRecordingStillGetsAFile() {
        let clip = Recording(createdAt: date(2026, 7, 31, 9, 0, 0), duration: 3,
                             audioFileName: "a.m4a", origin: .phone)
        let inbox = Document(title: inboxTitle, recordings: [clip])
        let plan = MarkdownBackup.plan(for: [inbox], inboxTitle: inboxTitle)
        XCTAssertEqual(Array(plan.keys), ["Inbox/2026-07-31 09-00-00.md"])
        XCTAssertTrue(plan.values.first?.contains("*iPhone · 0:03*") ?? false)
    }

    func testImportedTextEntryIsMarkedTextOnlyAndAlreadyDone() {
        let entry = Recording.textEntry("Pasted from the trail guide.", origin: .phone)
        XCTAssertTrue(entry.isTextOnly)
        XCTAssertEqual(entry.status, .done)
        XCTAssertEqual(entry.transcript, "Pasted from the trail guide.")
        XCTAssertEqual(entry.duration, 0)
        // A captured clip is never mistaken for one.
        XCTAssertFalse(Recording(audioFileName: "a.m4a", origin: .phone).isTextOnly)
    }

    func testImportedTextEntryBacksUpAsImportedText() {
        // A device name and a "0:00" would be a lie here: nothing was captured.
        let entry = Recording.textEntry("Pasted.", createdAt: date(2026, 7, 31, 14, 30, 5),
                                        origin: .phone)
        let markdown = MarkdownBackup.markdown(for: entry)
        XCTAssertTrue(markdown.contains("*Imported text*"))
        XCTAssertFalse(markdown.contains("iPhone"))
        XCTAssertTrue(markdown.hasSuffix("Pasted.\n"))
    }

    func testCollidingNamesBothGetAnIdSuffix() {
        // Two documents with the same title: neither may keep the bare name, or the file a given
        // document maps to would depend on the order the list happens to be in.
        let a = Document(title: "Notes")
        let b = Document(title: "Notes")
        let plan = MarkdownBackup.plan(for: [a, b], inboxTitle: inboxTitle)
        XCTAssertEqual(plan.count, 2)
        XCTAssertFalse(plan.keys.contains("Documents/Notes.md"))
        XCTAssertTrue(plan.keys.contains("Documents/Notes-\(a.id.uuidString.prefix(8)).md"))
        XCTAssertTrue(plan.keys.contains("Documents/Notes-\(b.id.uuidString.prefix(8)).md"))
    }

    func testTwoClipsInTheSameSecondGetDistinctFiles() {
        let when = date(2026, 7, 31, 14, 30, 5)
        let inbox = Document(title: inboxTitle, recordings: [
            Recording(createdAt: when, audioFileName: "a.m4a", origin: .watch),
            Recording(createdAt: when, audioFileName: "b.m4a", origin: .watch)
        ])
        let plan = MarkdownBackup.plan(for: [inbox], inboxTitle: inboxTitle)
        XCTAssertEqual(plan.count, 2)
    }

    func testSafeFileNameStripsPathCharactersAndFallsBack() {
        XCTAssertEqual(MarkdownBackup.safeFileName("Trip: 7/12", fallback: "Document"), "Trip- 7-12")
        XCTAssertEqual(MarkdownBackup.safeFileName("  ", fallback: "Document"), "Document")
        XCTAssertEqual(MarkdownBackup.safeFileName("..", fallback: "Document"), "Document")
        XCTAssertEqual(MarkdownBackup.safeFileName(String(repeating: "a", count: 400),
                                                   fallback: "Document").count, 120)
    }

    // MARK: Widget snapshot / deep links

    func testWidgetSnapshotExcludesInboxAndOrdersPinnedFirstThenRecent() {
        let older = Document(title: "Older", updatedAt: date(2026, 7, 1, 9, 0, 0))
        let newer = Document(title: "Newer", updatedAt: date(2026, 7, 30, 9, 0, 0))
        let pinned = Document(title: "Pinned", updatedAt: date(2026, 6, 1, 9, 0, 0), isPinned: true)
        let inbox = Document(title: inboxTitle, updatedAt: date(2026, 7, 31, 9, 0, 0))

        let rows = WidgetSnapshotStore.snapshot(of: [older, inbox, newer, pinned],
                                                inboxTitle: inboxTitle)

        XCTAssertEqual(rows.map(\.title), ["Pinned", "Newer", "Older"])
        XCTAssertEqual(rows.map(\.id), [pinned.id, newer.id, older.id])
    }

    func testWidgetSnapshotIsCapped() {
        let docs = (0..<20).map { Document(title: "Doc \($0)") }
        let rows = WidgetSnapshotStore.snapshot(of: docs, inboxTitle: inboxTitle)
        XCTAssertEqual(rows.count, WidgetSnapshotStore.maxDocuments)
    }

    func testWidgetPreviewIsFirstNonEmptyParagraphCollapsedToOneLine() {
        let doc = Document(title: "Notes", paragraphs: [
            .init(text: "   "),
            .init(text: "Elk by the creek.\nTwo of them."),
            .init(text: "Second paragraph.")
        ])
        XCTAssertEqual(WidgetSnapshotStore.preview(of: doc), "Elk by the creek. Two of them.")
        XCTAssertEqual(WidgetSnapshotStore.preview(of: Document(title: "Empty")), "")
    }

    func testWidgetPreviewIsLengthCapped() {
        let doc = Document(title: "Long",
                           paragraphs: [.init(text: String(repeating: "a", count: 500))])
        XCTAssertEqual(WidgetSnapshotStore.preview(of: doc).count, 160)
    }

    func testWidgetSnapshotRoundTripsThroughTheSharedEncoder() throws {
        // A whole-second date: the shared ISO-8601 coding drops fractional seconds, so a
        // Date()-fresh document wouldn't compare equal after the round trip.
        let doc = Document(title: "Field Notes",
                           updatedAt: date(2026, 7, 31, 9, 0, 0),
                           paragraphs: [.init(text: "Hi.")],
                           isPinned: true)
        let rows = WidgetSnapshotStore.snapshot(of: [doc], inboxTitle: inboxTitle)
        let decoded = try JSONDecoder.iso.decode([WidgetDocument].self,
                                                 from: JSONEncoder.iso.encode(rows))
        XCTAssertEqual(decoded, rows)
    }

    func testDocumentDeepLinkRoundTrips() {
        let id = UUID()
        XCTAssertEqual(woodsWhisperDocumentID(from: woodsWhisperDocumentURL(id: id)), id)
    }

    // The small widget family's tap route (the other families link by URL, covered above).
    #if os(iOS)
    @available(iOS 17.0, *)
    @MainActor
    func testOpenDocumentIntentHandsTheDocumentIDToTheLauncher() async throws {
        let id = UUID()
        _ = try await OpenDocumentIntent(documentID: id).perform()
        XCTAssertEqual(DocumentLauncher.shared.pendingDocumentID, id)
        DocumentLauncher.shared.pendingDocumentID = nil
    }
    #endif

    func testDocumentDeepLinkRejectsOtherURLs() {
        XCTAssertNil(woodsWhisperDocumentID(from: woodsWhisperRecordURL))
        XCTAssertNil(woodsWhisperDocumentID(from: woodsWhisperDocumentsURL))
        XCTAssertNil(woodsWhisperDocumentID(from: URL(string: "woodswhisper://document/not-a-uuid")!))
        XCTAssertNil(woodsWhisperDocumentID(from: URL(string: "https://document/\(UUID().uuidString)")!))
    }

    /// Copy Markdown Link: the document's name as the link text, and the same link Copy Link hands
    /// out behind it — which still opens the document.
    func testAMarkdownLinkNamesTheDocumentAndCarriesItsLink() {
        let id = UUID()
        let link = woodsWhisperDocumentMarkdownLink(id: id, title: "Field Notes")
        XCTAssertEqual(link, "[Field Notes](woodswhisper://document/\(id.uuidString))")

        let address = String(link[link.index(after: link.firstIndex(of: "(")!)..<link.lastIndex(of: ")")!])
        XCTAssertEqual(woodsWhisperDocumentID(from: URL(string: address)!), id)
    }

    /// A title can't break the link it names: brackets and backslashes are escaped, a line break
    /// becomes a space, and a document with no title is still something to click.
    func testAMarkdownLinkEscapesWhatWouldBreakIt() {
        let id = UUID()
        let url = woodsWhisperDocumentURL(id: id).absoluteString
        XCTAssertEqual(woodsWhisperDocumentMarkdownLink(id: id, title: #"Plan [draft] \ v2"#),
                       #"[Plan \[draft\] \\ v2]("# + url + ")")
        XCTAssertEqual(woodsWhisperDocumentMarkdownLink(id: id, title: "Two\nlines"),
                       "[Two lines](\(url))")
        XCTAssertEqual(woodsWhisperDocumentMarkdownLink(id: id, title: "  "), "[Untitled](\(url))")
    }

    // MARK: Graph documents

    /// A node with just the two things these tests care about: what it says and where it hangs.
    private func graphNode(_ text: String, parent: UUID? = nil,
                           x: Double = 0, y: Double = 0) -> GraphNode {
        GraphNode(text: text, parentID: parent, position: GraphPoint(x: x, y: y))
    }

    func testDocumentsAreOrdinaryDocumentsUnlessAskedOtherwise() {
        XCTAssertEqual(Document(title: "Notes").kind, .document)
        XCTAssertFalse(Document(title: "Notes").isGraph)
        XCTAssertTrue(Document(title: "Map", kind: .graph).isGraph)
    }

    func testGraphRoundTripsKindStructureAndPositions() throws {
        let root = graphNode("Trailhead")
        let child = graphNode("Water at the creek", parent: root.id, x: 190, y: 40)
        let doc = Document(title: "Route", kind: .graph, nodes: [root, child])

        let decoded = try JSONDecoder.iso.decode(Document.self, from: JSONEncoder.iso.encode(doc))

        XCTAssertEqual(decoded.kind, .graph)
        XCTAssertEqual(decoded.nodes.count, 2)
        XCTAssertEqual(decoded.node(with: child.id)?.parentID, root.id)
        XCTAssertEqual(decoded.node(with: child.id)?.position, GraphPoint(x: 190, y: 40))
    }

    /// A document saved before graphs existed still loads — and reads as an ordinary document.
    func testDocumentWithoutAKindKeyDecodesAsADocument() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Field Notes",\
        "createdAt":"2026-07-31T14:30:05Z","updatedAt":"2026-07-31T14:30:05Z"}
        """
        let decoded = try JSONDecoder.iso.decode(Document.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .document)
        XCTAssertTrue(decoded.nodes.isEmpty)
        XCTAssertTrue(decoded.groups.isEmpty)
    }

    func testGroupsRoundTripAndCarryTheirLabel() throws {
        let camp = graphNode("Camp")
        let firewood = graphNode("Firewood", y: 120)
        let doc = Document(title: "Trip", kind: .graph,
                           nodes: [camp, firewood],
                           groups: [GraphGroup(label: "  Overnight  ",
                                               memberIDs: [camp.id, firewood.id])])

        let decoded = try JSONDecoder.iso.decode(Document.self, from: JSONEncoder.iso.encode(doc))

        XCTAssertEqual(decoded.groups.count, 1)
        XCTAssertEqual(decoded.groups.first?.trimmedLabel, "Overnight")
        XCTAssertEqual(decoded.groups.first?.members, [camp.id, firewood.id])
        // A ring round one node isn't a ring round anything.
        XCTAssertEqual(GraphGroup.minimumMembers, 2)
    }

    func testAGroupWithoutALabelSaysSo() {
        let group = GraphGroup(memberIDs: [UUID(), UUID()])
        XCTAssertFalse(group.hasLabel)
        XCTAssertTrue(GraphGroup(label: "   ", memberIDs: []).trimmedLabel.isEmpty)
    }

    /// Groups are annotation, not structure: the outline walks straight past them.
    func testGroupsDoNotChangeTheOutline() {
        let camp = graphNode("Camp")
        let firewood = graphNode("Firewood", parent: camp.id, y: 60)
        let grouped = Document(title: "Trip", kind: .graph, nodes: [camp, firewood],
                               groups: [GraphGroup(label: "Overnight",
                                                   memberIDs: [camp.id, firewood.id])])
        let plain = Document(title: "Trip", kind: .graph, nodes: [camp, firewood])
        XCTAssertEqual(grouped.outline, plain.outline)
    }

    func testOutlineIndentsByDepthInTheOrderTheCanvasReads() {
        // Deliberately out of order in the array: the outline follows the canvas, not the array.
        let camp = graphNode("Camp", y: 0)
        let weather = graphNode("Weather", y: 300)
        let firewood = graphNode("Firewood by the log", parent: camp.id, y: 60)
        let enough = graphNode("Enough for two nights", parent: firewood.id, y: 90)
        let doc = Document(title: "Trip", kind: .graph, nodes: [enough, weather, firewood, camp])

        XCTAssertEqual(doc.outline, """
                                    - Camp
                                      - Firewood by the log
                                        - Enough for two nights
                                    - Weather
                                    """)
    }

    func testOutlineLeavesOutEmptyNodesAndPromotesWhatHangsOffThem() {
        let stillTranscribing = graphNode("", y: 0)
        let child = graphNode("Elk by the creek", parent: stillTranscribing.id, y: 40)
        let doc = Document(title: "Trip", kind: .graph, nodes: [stillTranscribing, child])
        XCTAssertEqual(doc.outline, "- Elk by the creek")
    }

    func testOutlineKeepsAMultiLineNodeAsOneBullet() {
        let doc = Document(title: "Trip", kind: .graph,
                           nodes: [graphNode("First line.\nSecond line.")])
        XCTAssertEqual(doc.outline, "- First line.\n  Second line.")
    }

    func testGraphCopiesSharesAndBacksUpAsItsOutline() {
        let camp = graphNode("Camp")
        let doc = Document(title: "Trip", kind: .graph,
                           nodes: [camp, graphNode("Firewood", parent: camp.id, y: 60)])

        XCTAssertEqual(doc.combinedText, "- Camp\n  - Firewood")
        XCTAssertEqual(MarkdownBackup.markdown(for: doc), "# Trip\n\n- Camp\n  - Firewood\n")
        XCTAssertTrue(doc.hasBodyText)
    }

    func testGraphWithNothingSaidYetHasNoBody() {
        let doc = Document(title: "Blank", kind: .graph, nodes: [graphNode("")])
        XCTAssertFalse(doc.hasBodyText)
        XCTAssertEqual(MarkdownBackup.markdown(for: doc), "# Blank\n")
    }

    func testGraphsAreMirroredAlongsideDocuments() {
        let doc = Document(title: "Route", kind: .graph, nodes: [graphNode("Trailhead")])
        let plan = MarkdownBackup.plan(for: [doc], inboxTitle: inboxTitle)
        XCTAssertEqual(Array(plan.keys), ["Documents/Route.md"])
    }

    func testSubtreeCarriesEverythingBelowANode() {
        let root = graphNode("Root")
        let child = graphNode("Child", parent: root.id)
        let grandchild = graphNode("Grandchild", parent: child.id)
        let elsewhere = graphNode("Elsewhere")
        let doc = Document(title: "G", kind: .graph, nodes: [root, child, grandchild, elsewhere])

        XCTAssertEqual(Set(doc.subtree(of: root.id)), [root.id, child.id, grandchild.id])
        XCTAssertEqual(doc.subtree(of: elsewhere.id), [elsewhere.id])
    }

    /// The test a re-parenting drop has to pass: a node may not be hung off its own descendant.
    func testAncestryIsWhatKeepsAReparentFromMakingACycle() {
        let root = graphNode("Root")
        let child = graphNode("Child", parent: root.id)
        let grandchild = graphNode("Grandchild", parent: child.id)
        let doc = Document(title: "G", kind: .graph, nodes: [root, child, grandchild])

        XCTAssertTrue(doc.isAncestor(root.id, of: grandchild.id))
        XCTAssertFalse(doc.isAncestor(grandchild.id, of: root.id))
        XCTAssertFalse(doc.isAncestor(root.id, of: root.id))
    }

    func testWidgetPreviewOfAGraphIsItsFirstBullet() {
        let waiting = graphNode("", y: 0)
        let doc = Document(title: "Trip", kind: .graph,
                           nodes: [waiting, graphNode("Elk by the creek", parent: waiting.id, y: 30)])
        XCTAssertEqual(WidgetSnapshotStore.preview(of: doc), "Elk by the creek")
    }

    func testNodeListIsOutlineOrderWithDepthsAndKeepsEmptyNodes() {
        // The list is how you find your way back to a node, so a clip still transcribing — no words
        // yet — has to be in it, even though the outline leaves it out.
        let camp = graphNode("Camp", y: 0)
        let waiting = graphNode("", parent: camp.id, y: 40)
        let firewood = graphNode("Firewood", parent: waiting.id, y: 60)
        let weather = graphNode("Weather", y: 300)
        let doc = Document(title: "Trip", kind: .graph,
                           nodes: [weather, firewood, waiting, camp])

        let entries = doc.nodeEntries
        XCTAssertEqual(entries.map(\.node.id), [camp.id, waiting.id, firewood.id, weather.id])
        XCTAssertEqual(entries.map(\.depth), [0, 1, 2, 0])
        // …while the export still promotes what hangs off the empty one.
        XCTAssertEqual(doc.outline, "- Camp\n  - Firewood\n- Weather")
    }

    // MARK: Node headings

    func testAHashMakesTheBiggerHeadingAndTwoTheSmaller() {
        let big = GraphHeading.parse("# Camp")
        XCTAssertEqual(big?.level, 1)
        XCTAssertEqual(big?.text, "Camp")
        XCTAssertEqual(big?.extraPoints, 7)

        let small = GraphHeading.parse("## Firewood")
        XCTAssertEqual(small?.level, 2)
        XCTAssertEqual(small?.text, "Firewood")
        XCTAssertEqual(small?.extraPoints, 4)
    }

    /// Markdown wants a space after the marker; someone typing into a card two inches wide often
    /// doesn't. Both count.
    func testAMarkerWithoutASpaceStillReadsAsAHeading() {
        XCTAssertEqual(GraphHeading.parse("#Camp")?.text, "Camp")
        XCTAssertEqual(GraphHeading.parse("  ##  Firewood ")?.text, "Firewood")
    }

    func testWhatIsNotAHeading() {
        XCTAssertNil(GraphHeading.parse("Camp"))
        XCTAssertNil(GraphHeading.parse("### Too deep"))   // not one of the two sizes drawn
        XCTAssertNil(GraphHeading.parse("#"))              // nothing to make large yet
        XCTAssertNil(GraphHeading.parse("##   "))
        XCTAssertNil(GraphHeading.parse("Camp # 3"))       // a hash in the middle is a hash
    }

    /// The marker is invisible on the canvas and still there in the text — which is what lets you
    /// edit it away again, and what keeps the export a Markdown outline with headings in it.
    func testAHeadingHidesItsMarkerButKeepsItInTheText() {
        let node = graphNode("## Firewood by the log")
        XCTAssertEqual(node.heading?.level, 2)
        XCTAssertEqual(node.displayText, "Firewood by the log")
        XCTAssertEqual(node.trimmedText, "## Firewood by the log")
        XCTAssertEqual(Document(title: "Trip", kind: .graph, nodes: [node]).outline,
                       "- ## Firewood by the log")
    }

    func testAHeadingKeepsTheLinesUnderIt() {
        XCTAssertEqual(GraphHeading.parse("# Camp\nby the creek")?.text, "Camp\nby the creek")
    }

    func testAnOrdinaryNodeShowsExactlyWhatItSays() {
        XCTAssertNil(graphNode("Camp").heading)
        XCTAssertEqual(graphNode("  Camp  ").displayText, "Camp")
    }

    // MARK: Node and group colour

    func testAColourRoundTripsOnNodesAndGroups() throws {
        let camp = GraphNode(text: "Camp", colorID: "violet")
        let firewood = graphNode("Firewood", y: 120)
        let doc = Document(title: "Trip", kind: .graph,
                           nodes: [camp, firewood],
                           groups: [GraphGroup(label: "Overnight",
                                               memberIDs: [camp.id, firewood.id],
                                               colorID: "amber")])

        let decoded = try JSONDecoder.iso.decode(Document.self, from: JSONEncoder.iso.encode(doc))

        XCTAssertEqual(decoded.node(with: camp.id)?.colorID, "violet")
        XCTAssertNil(decoded.node(with: firewood.id)?.colorID)
        XCTAssertEqual(decoded.groups.first?.colorID, "amber")
    }

    /// A graph saved before colours existed still loads — everything on the canvas's own ink.
    func testANodeWithoutAColourKeyDecodesAsUncoloured() throws {
        let json = """
        {"id":"\(UUID().uuidString)","text":"Camp","position":{"x":0,"y":0},\
        "createdAt":"2026-07-31T14:30:05Z"}
        """
        let node = try JSONDecoder.iso.decode(GraphNode.self, from: Data(json.utf8))
        XCTAssertNil(node.colorID)
        XCTAssertEqual(node.text, "Camp")
    }

    /// One vocabulary of colour across the app: a node, a group and an Inbox tag name their inks
    /// from the same list, so "the amber one" means the same thing wherever it's said.
    func testTheGraphPaletteIsTheAppsOneVocabularyOfColour() {
        XCTAssertEqual(GraphPalette.colorIDs, InboxTag.paletteIDs)
        XCTAssertTrue(GraphPalette.isKnown("violet"))
        XCTAssertFalse(GraphPalette.isKnown(nil))
        XCTAssertFalse(GraphPalette.isKnown("chartreuse"))
    }

    // MARK: Copying nodes (⌥ + drag)

    @MainActor
    func testACopyKeepsTheShapeInsideTheSetAndDropsWhatLeavesIt() {
        let name = "GraphCopyTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let root = store.addRootNode(in: graph.id, text: "Camp")!
        let child = store.addChildNode(to: root.id, in: graph.id, text: "Firewood")!
        let grandchild = store.addChildNode(to: child.id, in: graph.id, text: "By the log")!

        // The child and its own child come away; the root above them doesn't.
        let map = store.duplicateNodes([child.id, grandchild.id], in: graph.id)
        let document = store.document(with: graph.id)!

        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(document.nodes.count, 5)
        let childCopy = document.node(with: map[child.id]!)!
        let grandchildCopy = document.node(with: map[grandchild.id]!)!
        XCTAssertNil(childCopy.parentID)                          // the link out of the set is gone
        XCTAssertEqual(grandchildCopy.parentID, childCopy.id)     // the one inside it survives
        XCTAssertEqual(childCopy.text, "Firewood")
        XCTAssertEqual(childCopy.position, child.position)        // it's dragged from where it stood
        XCTAssertEqual(document.node(with: child.id)?.parentID, root.id)   // original untouched
    }

    /// A node owns the clip it was spoken into, so a copy that pointed at the same one would delete
    /// the original's audio the day it was deleted itself. The copy keeps the words, not the tape.
    @MainActor
    func testACopyCarriesTheWordsButNotTheTape() {
        let name = "GraphCopyTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let node = store.addRootNode(in: graph.id, text: "Elk by the creek")!
        store.linkNode(node.id, toRecording: UUID(), in: graph.id)

        let map = store.duplicateNodes([node.id], in: graph.id)
        let document = store.document(with: graph.id)!

        XCTAssertNil(document.node(with: map[node.id]!)?.recordingID)
        XCTAssertNotNil(document.node(with: node.id)?.recordingID)
        XCTAssertEqual(document.node(with: map[node.id]!)?.text, "Elk by the creek")
    }

    @MainActor
    func testCopyingAGroupDrawsAFreshRingRoundTheCopies() {
        let name = "GraphCopyTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let camp = store.addRootNode(in: graph.id, text: "Camp")!
        let firewood = store.addRootNode(in: graph.id, text: "Firewood")!
        let group = store.addGroup(members: [camp.id, firewood.id], in: graph.id)!
        store.setGroupLabel(group.id, in: graph.id, to: "Overnight")
        store.setGroupColor(group.id, in: graph.id, to: "amber")

        let map = store.duplicateGroup(group.id, in: graph.id)
        let document = store.document(with: graph.id)!

        XCTAssertEqual(document.nodes.count, 4)
        XCTAssertEqual(document.groups.count, 2)
        let copy = document.groups.last!
        XCTAssertEqual(copy.trimmedLabel, "Overnight")
        XCTAssertEqual(copy.colorID, "amber")
        XCTAssertEqual(copy.members, Set(map.values))
        XCTAssertEqual(document.groups.first?.members, [camp.id, firewood.id])
    }

    @MainActor
    func testANodesInkIsSetAndTakenOffAgain() {
        let name = "GraphColourTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let node = store.addRootNode(in: graph.id, text: "Camp")!

        store.setNodeColor(node.id, in: graph.id, to: "slate")
        XCTAssertEqual(store.document(with: graph.id)?.node(with: node.id)?.colorID, "slate")
        store.setNodeColor(node.id, in: graph.id, to: nil)
        XCTAssertNil(store.document(with: graph.id)?.node(with: node.id)?.colorID)
    }

    /// ⌘T with nothing picked out: every row in the graph, from the roots down — so a row whose
    /// parent has just been moved is arranged where the parent ended up.
    @MainActor
    func testTidyingTheWholeGraphLinesUpEveryRow() {
        let name = "GraphTidyTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let root = store.addRootNode(in: graph.id, text: "Camp")!
        let first = store.addChildNode(to: root.id, in: graph.id, text: "Firewood")!
        let second = store.addChildNode(to: root.id, in: graph.id, text: "Water")!
        let grandchild = store.addChildNode(to: first.id, in: graph.id, text: "By the log")!
        // Pile them all on the origin: nothing on this canvas moves by itself.
        store.moveNodes([first.id: .zero, second.id: .zero, grandchild.id: .zero], in: graph.id)

        store.tidyGraph(in: graph.id)
        let document = store.document(with: graph.id)!

        let column = root.position.x + DocumentStore.childColumnOffset
        let children = document.children(of: root.id)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children.map(\.position.x), [column, column])
        XCTAssertNotEqual(children[0].position.y, children[1].position.y)
        // The row below was arranged too, beside the parent the pass above had just placed.
        XCTAssertEqual(document.node(with: grandchild.id)?.position.x,
                       column + DocumentStore.childColumnOffset)
    }

    // MARK: Which way a branch runs

    /// The direction is read off the layout, and a tie takes the canvas's own.
    func testABranchsDirectionIsReadFromWhereItsChildrenSit() {
        let parent = GraphNode(text: "Camp", position: GraphPoint(x: 0, y: 0))
        func graph(_ children: [GraphPoint]) -> Document {
            Document(title: "Route", kind: .graph,
                     nodes: [parent] + children.map {
                         GraphNode(parentID: parent.id, position: $0)
                     })
        }
        // A column out to the right, centred on the parent: the cross-axis offsets cancel.
        XCTAssertEqual(graph([GraphPoint(x: 330, y: -90), GraphPoint(x: 330, y: 90)])
                        .branchAxis(of: parent.id), .right)
        XCTAssertEqual(graph([GraphPoint(x: -330, y: -90), GraphPoint(x: -330, y: 90)])
                        .branchAxis(of: parent.id), .left)
        // A row underneath, spread across it.
        XCTAssertEqual(graph([GraphPoint(x: -200, y: 86), GraphPoint(x: 200, y: 86)])
                        .branchAxis(of: parent.id), .down)
        XCTAssertEqual(graph([GraphPoint(x: -200, y: -86), GraphPoint(x: 200, y: -86)])
                        .branchAxis(of: parent.id), .up)
        // Nothing to read: children on top of their parent, and a parent with no children at all.
        XCTAssertEqual(graph([GraphPoint(x: 0, y: 0)]).branchAxis(of: parent.id), .right)
        XCTAssertEqual(graph([]).branchAxis(of: parent.id), .right)
    }

    /// The bug this was written for: two nodes one above the other, a third dropped between them
    /// with the "+", and Auto tidy swinging the whole branch round to the side.
    @MainActor
    func testTidyKeepsADownwardBranchDownward() {
        let name = "GraphAxisTidyTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let parent = store.addRootNode(in: graph.id, text: "Camp")!
        let below = store.addChildNode(to: parent.id, in: graph.id, text: "Firewood")!
        // Put the child under its parent rather than beside it — the arrangement being defended.
        store.moveNodes([below.id: GraphPoint(x: 0, y: 200)], in: graph.id)

        let middle = store.insertNode(between: parent.id, and: below.id, in: graph.id)!
        store.tidyChildren(of: parent.id, in: graph.id)

        let document = store.document(with: graph.id)!
        let tidied = document.node(with: middle.id)!
        XCTAssertGreaterThan(tidied.position.y, parent.position.y,
                             "a child drawn below its parent should be tidied below it")
        XCTAssertEqual(tidied.position.x, parent.position.x, accuracy: 0.001,
                       "one child in a downward row sits under the middle of its parent")
        // And the branch below it came along rather than being left behind.
        XCTAssertGreaterThan(document.node(with: below.id)!.position.y, tidied.position.y)
    }

    /// Two children in a row under their parent: spread across it, level with each other, and not
    /// stacked into a column off to one side.
    @MainActor
    func testTidySpreadsADownwardRowAcross() {
        let name = "GraphAxisRowTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let parent = store.addRootNode(in: graph.id, text: "Camp")!
        let left = store.addChildNode(to: parent.id, in: graph.id, text: "Firewood")!
        let right = store.addChildNode(to: parent.id, in: graph.id, text: "Water")!
        store.moveNodes([left.id: GraphPoint(x: -300, y: 190),
                         right.id: GraphPoint(x: 300, y: 210)], in: graph.id)

        store.tidyChildren(of: parent.id, in: graph.id)
        let document = store.document(with: graph.id)!
        let a = document.node(with: left.id)!
        let b = document.node(with: right.id)!

        XCTAssertEqual(a.position.y, b.position.y, accuracy: 0.001, "a row is level")
        XCTAssertGreaterThan(a.position.y, parent.position.y)
        XCTAssertNotEqual(a.position.x, b.position.x)
        // Centred on the parent, and a clear card's width of air between the two of them.
        XCTAssertEqual((a.position.x + b.position.x) / 2, parent.position.x, accuracy: 0.001)
        XCTAssertEqual(abs(b.position.x - a.position.x), 180 + 150, accuracy: 0.001)
    }

    /// The "+" on a card follows the row it's joining rather than always striking out to the right.
    @MainActor
    func testAddingAChildFollowsTheRowItJoins() {
        let name = "GraphAxisAddTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let parent = store.addRootNode(in: graph.id, text: "Camp")!
        // The first child has no row to join, so it goes out to the right as it always has.
        let first = store.addChildNode(to: parent.id, in: graph.id, text: "Firewood")!
        XCTAssertGreaterThan(first.position.x, parent.position.x)
        XCTAssertEqual(first.position.y, parent.position.y, accuracy: 0.001)

        // Turn the branch downwards; the next child joins it there.
        store.moveNodes([first.id: GraphPoint(x: 0, y: 200)], in: graph.id)
        let second = store.addChildNode(to: parent.id, in: graph.id, text: "Water")!
        XCTAssertGreaterThan(second.position.y, parent.position.y)
    }

    // MARK: Lining a selection up

    /// A card the size the canvas draws them, centred where it's told.
    private func box(_ x: Double, _ y: Double, width: Double = 180, height: Double = 60) -> GraphNodeBox {
        GraphNodeBox(id: UUID(), center: GraphPoint(x: x, y: y), width: width, height: height)
    }

    func testAlignLeftPutsEveryLeftEdgeOnTheLeftmostOne() {
        let boxes = [box(400, 0), box(100, 90), box(260, 180)]
        let moved = GraphArrange.alignLeft(boxes)

        // The leftmost card is already where it belongs, so it isn't moved at all.
        XCTAssertNil(moved[boxes[1].id])
        XCTAssertEqual(moved[boxes[0].id]?.x, 100)
        XCTAssertEqual(moved[boxes[2].id]?.x, 100)
        // Aligning one edge leaves the other axis alone.
        XCTAssertEqual(moved[boxes[0].id]?.y, 0)
        XCTAssertEqual(moved[boxes[2].id]?.y, 180)
    }

    /// ⌘→, where ⌘← is align left. Cards differ in width, so this is the right *edges*.
    func testAlignRightPutsEveryRightEdgeOnTheRightmostOne() {
        let wide = box(0, 0, width: 300)         // right edge at 150
        let narrow = box(400, 90, width: 100)    // right edge at 450 — the rightmost
        let moved = GraphArrange.alignRight([wide, narrow])

        XCTAssertNil(moved[narrow.id])
        XCTAssertEqual(moved[wide.id]?.x, 300)   // 450 − 300/2
        XCTAssertEqual(moved[wide.id]?.y, 0)
    }

    /// Cards differ in height, so aligning tops is about edges rather than centres.
    func testAlignTopMeasuresFromEachCardsOwnTopEdge() {
        let short = box(0, 100, height: 40)      // top edge at 80
        let tall = box(300, 200, height: 120)    // top edge at 140
        let moved = GraphArrange.alignTop([short, tall])

        XCTAssertNil(moved[short.id])
        XCTAssertEqual(moved[tall.id]?.y, 140)   // 80 + 120/2
        XCTAssertEqual(moved[tall.id]?.x, 300)
    }

    func testDistributeHorizontallyEvensTheGapsAndLeavesTheEndsWhereTheyAre() {
        let left = box(0, 0)
        let middle = box(100, 0)
        let right = box(900, 0)
        let moved = GraphArrange.distributeHorizontally([middle, right, left])

        XCTAssertNil(moved[left.id])
        XCTAssertNil(moved[right.id])
        // Three 180-wide cards spanning -90…990: 1080 of span, 540 of card, 270 of gap either side.
        XCTAssertEqual(moved[middle.id]?.x ?? 0, 450, accuracy: 0.001)
    }

    /// Down the page the gaps are between *edges*, so a tall card doesn't crowd its neighbours.
    func testDistributeVerticallyEvensTheGapsBetweenEdges() {
        let top = box(0, 0, height: 40)          // top edge at -20
        let middle = box(0, 100, height: 200)    // the tall one
        let bottom = box(0, 500, height: 40)     // bottom edge at 520
        let moved = GraphArrange.distributeVertically([top, middle, bottom])

        XCTAssertNil(moved[top.id])
        XCTAssertNil(moved[bottom.id])
        // Span -20…520 is 540; 280 of card leaves 260 of air, so 130 above and below the middle.
        XCTAssertEqual(moved[middle.id]?.y ?? 0, 250, accuracy: 0.001)
    }

    func testDistributingNeedsThreeAndAligningNeedsTwo() {
        XCTAssertTrue(GraphArrange.distributeHorizontally([box(0, 0), box(400, 0)]).isEmpty)
        XCTAssertTrue(GraphArrange.distributeVertically([box(0, 0), box(0, 400)]).isEmpty)
        XCTAssertTrue(GraphArrange.alignLeft([box(0, 0)]).isEmpty)
        XCTAssertTrue(GraphArrange.alignRight([box(0, 0)]).isEmpty)
        XCTAssertTrue(GraphArrange.alignTop([box(0, 0)]).isEmpty)
    }

    /// Nothing to do is nothing done — a no-op arrangement doesn't move (or re-save) a single card.
    func testArrangingWhatIsAlreadyArrangedMovesNothing() {
        let column = [box(0, 0), box(0, 200), box(0, 400)]
        XCTAssertTrue(GraphArrange.alignLeft(column).isEmpty)
        XCTAssertTrue(GraphArrange.distributeVertically(column).isEmpty)
    }

    // MARK: Resizing a card

    func testAWidthRoundTripsAndAnOlderNodeDecodesWithoutOne() throws {
        let wide = GraphNode(text: "A long thought", width: 360)
        let decoded = try JSONDecoder.iso.decode(GraphNode.self, from: JSONEncoder.iso.encode(wide))
        XCTAssertEqual(decoded.width, 360)

        let json = """
        {"id":"\(UUID().uuidString)","text":"Camp","position":{"x":0,"y":0},\
        "createdAt":"2026-07-31T14:30:05Z"}
        """
        XCTAssertNil(try JSONDecoder.iso.decode(GraphNode.self, from: Data(json.utf8)).width)
    }

    @MainActor
    func testResizingStoresTheWidthAndTheCentreTogether() {
        let name = "GraphResizeTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let node = store.addRootNode(in: graph.id, text: "Camp")!
        store.resizeNode(node.id, in: graph.id, width: 300, position: GraphPoint(x: 60, y: 10))
        var stored = store.document(with: graph.id)?.node(with: node.id)
        XCTAssertEqual(stored?.width, 300)
        XCTAssertEqual(stored?.position, GraphPoint(x: 60, y: 10))

        // Back to the standard card.
        store.resizeNode(node.id, in: graph.id, width: nil, position: .zero)
        stored = store.document(with: graph.id)?.node(with: node.id)
        XCTAssertNil(stored?.width)
    }

    /// A selection resized by one of its cards: every card takes that width, each keeping its own
    /// place — and a card outside the selection is left alone.
    @MainActor
    func testResizingASelectionGivesEveryCardTheSameWidth() {
        let name = "GraphResizeManyTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let camp = store.addRootNode(in: graph.id, text: "Camp")!
        let water = store.addRootNode(in: graph.id, text: "Water")!
        let wood = store.addRootNode(in: graph.id, text: "Firewood")!
        store.resizeNodes([camp.id: GraphPoint(x: 10, y: 0), water.id: GraphPoint(x: 10, y: 200)],
                          in: graph.id, width: 320)

        let document = store.document(with: graph.id)!
        XCTAssertEqual(document.node(with: camp.id)?.width, 320)
        XCTAssertEqual(document.node(with: water.id)?.width, 320)
        XCTAssertEqual(document.node(with: water.id)?.position, GraphPoint(x: 10, y: 200))
        XCTAssertNil(document.node(with: wood.id)?.width)
        XCTAssertEqual(document.node(with: wood.id)?.position, wood.position)
    }

    /// A column of children keeps its near edges in line with a wide card among them, and a wide
    /// parent pushes its column out past its own edge.
    @MainActor
    func testTidySpacesCardsByTheirOwnWidths() {
        let name = "GraphWidthTidyTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let root = store.addRootNode(in: graph.id, text: "Camp")!
        let narrow = store.addChildNode(to: root.id, in: graph.id, text: "Firewood")!
        let wide = store.addChildNode(to: root.id, in: graph.id, text: "Water")!
        store.resizeNode(wide.id, in: graph.id, width: 380, position: wide.position)

        store.tidyChildren(of: root.id, in: graph.id)
        var document = store.document(with: graph.id)!
        // Standard cards: the column it has always been.
        XCTAssertEqual(document.node(with: narrow.id)!.position.x,
                       root.position.x + DocumentStore.childColumnOffset, accuracy: 0.001)
        // The wide one's left edge is where the narrow one's is.
        XCTAssertEqual(document.node(with: wide.id)!.position.x - 190,
                       document.node(with: narrow.id)!.position.x - 90, accuracy: 0.001)

        // A measured width (an emoji's square, say) wins over the stored one.
        store.tidyChildren(of: root.id, in: graph.id, widths: [root.id: 96])
        document = store.document(with: graph.id)!
        XCTAssertEqual(document.node(with: narrow.id)!.position.x,
                       root.position.x + 48 + DocumentStore.standardNodeGap + 90, accuracy: 0.001)
    }

    @MainActor
    func testACopyKeepsItsCardsWidth() {
        let name = "GraphWidthCopyTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let node = store.addRootNode(in: graph.id, text: "Camp")!
        store.resizeNode(node.id, in: graph.id, width: 240, position: .zero)
        let map = store.duplicateNodes([node.id], in: graph.id)
        let copy = store.document(with: graph.id)?.node(with: map[node.id]!)
        XCTAssertEqual(copy?.width, 240)
    }

    // MARK: Highlights

    func testAHighlightIsTheWordsBetweenTwoMarkers() {
        XCTAssertEqual(GraphHighlight.runs(in: "pack ==the stove== first"), [
            .init(text: "pack ", isHighlighted: false),
            .init(text: "the stove", isHighlighted: true),
            .init(text: " first", isHighlighted: false)
        ])
        XCTAssertEqual(GraphHighlight.runs(in: "==a== and ==b=="), [
            .init(text: "a", isHighlighted: true),
            .init(text: " and ", isHighlighted: false),
            .init(text: "b", isHighlighted: true)
        ])
    }

    /// Markdown's rules for emphasis: the words sit against the markers, on one line, and a marker
    /// that opens nothing stays exactly as it was typed.
    func testWhatIsNotAHighlight() {
        for text in ["x == y", "== spaced ==", "====", "==open", "==across\nlines=="] {
            XCTAssertEqual(GraphHighlight.runs(in: text), [.init(text: text, isHighlighted: false)],
                           text)
        }
        // A stray pair ahead of a real one doesn't swallow it.
        XCTAssertEqual(GraphHighlight.runs(in: "a == b ==c=="), [
            .init(text: "a == b ", isHighlighted: false),
            .init(text: "c", isHighlighted: true)
        ])
        XCTAssertTrue(GraphHighlight.runs(in: "").isEmpty)
    }

    func testPlainTextDropsTheHeadingAndHighlightMarkers() {
        XCTAssertEqual(GraphHighlight.stripped("keep ==this== dry"), "keep this dry")
        XCTAssertEqual(graphNode("# Camp ==tonight==").plainText, "Camp tonight")
        XCTAssertEqual(graphNode("a == b").plainText, "a == b")
    }

    // MARK: Blockquotes

    func testAQuoteIsTheLinesThatOpenWithAMarker() {
        XCTAssertEqual(GraphQuote.blocks(in: "Camp tonight\n> the creek is high\n> after rain"), [
            .init(text: "Camp tonight", depth: 0),
            .init(text: "the creek is high\nafter rain", depth: 1)
        ])
        // The space after the marker is optional, as it is in Markdown.
        XCTAssertEqual(GraphQuote.blocks(in: ">no space"), [.init(text: "no space", depth: 1)])
        XCTAssertTrue(GraphQuote.containsQuote("> quoted"))
        XCTAssertFalse(GraphQuote.containsQuote("plain"))
    }

    func testQuotesNestAndBreakTheWayMarkdownsDo() {
        // `>>` and `> >` are the same depth, and a run at one depth is one quotation.
        XCTAssertEqual(GraphQuote.blocks(in: "> outer\n>> inner\n> > also inner"), [
            .init(text: "outer", depth: 1),
            .init(text: "inner\nalso inner", depth: 2)
        ])
        // A quoted empty line is a paragraph break inside the quotation…
        XCTAssertEqual(GraphQuote.blocks(in: "> a\n>\n> b"), [.init(text: "a\n\nb", depth: 1)])
        // …and a blank line between two is two quotations.
        XCTAssertEqual(GraphQuote.blocks(in: "> a\n\n> b"), [
            .init(text: "a", depth: 1),
            .init(text: "b", depth: 1)
        ])
        // A line without the marker ends the quotation rather than running on into it.
        XCTAssertEqual(GraphQuote.blocks(in: "> quoted\nnot quoted"), [
            .init(text: "quoted", depth: 1),
            .init(text: "not quoted", depth: 0)
        ])
    }

    /// A marker that opens nothing, or one that isn't at the start of a line, stays as typed.
    func testWhatIsNotAQuote() {
        for text in [">", "a > b", "x\n>\ny", "-> next"] {
            XCTAssertEqual(GraphQuote.blocks(in: text), [.init(text: text, depth: 0)], text)
            XCTAssertFalse(GraphQuote.containsQuote(text), text)
        }
        XCTAssertTrue(GraphQuote.blocks(in: "").isEmpty)
    }

    /// Invisible on the card, still there in the text — and in the outline, where `- > words` is a
    /// quotation inside a bullet. A plain-text copy leaves it out with the other markers.
    func testAQuoteHidesItsMarkerButKeepsItInTheText() {
        let node = graphNode("> by the ==creek==")
        XCTAssertEqual(node.trimmedText, "> by the ==creek==")
        XCTAssertEqual(node.plainText, "by the creek")
        XCTAssertEqual(node.quoteBlocks, [.init(text: "by the ==creek==", depth: 1)])
        XCTAssertEqual(Document(title: "Trip", kind: .graph, nodes: [node]).outline,
                       "- > by the ==creek==")
        XCTAssertEqual(graphNode("# Camp\n> by the creek").plainText, "Camp\nby the creek")
    }

    // MARK: Copying nodes between graphs (Copy / Paste)

    func testACopyKeepsItsBranchAndLeavesItsParentAndTapeBehind() {
        let root = graphNode("Trip")
        var camp = graphNode("Camp", parent: root.id, x: 330)
        camp.recordingID = UUID()
        camp.colorID = "violet"
        let wood = graphNode("Firewood", parent: camp.id, x: 660)
        let doc = Document(title: "Route", kind: .graph, nodes: [root, camp, wood])

        let clipboard = GraphClipboard(copying: [camp.id, wood.id], from: doc)!
        XCTAssertEqual(clipboard.nodes.count, 2)
        let copiedCamp = clipboard.nodes.first { $0.id == camp.id }!
        XCTAssertNil(copiedCamp.parentID)                          // the parent stayed behind
        XCTAssertNil(copiedCamp.recordingID)                       // and so did the tape
        XCTAssertEqual(copiedCamp.colorID, "violet")               // but not how it's drawn
        XCTAssertEqual(clipboard.nodes.first { $0.id == wood.id }?.parentID, camp.id)
        XCTAssertNil(GraphClipboard(copying: [UUID()], from: doc))
    }

    /// A ring comes along only when everything in it did.
    func testACopyCarriesOnlyTheGroupsItHoldsWhole() {
        let a = graphNode("A"), b = graphNode("B", y: 90), c = graphNode("C", y: 180)
        let whole = GraphGroup(label: "Both", memberIDs: [a.id, b.id], colorID: "amber")
        let split = GraphGroup(label: "Split", memberIDs: [b.id, c.id])
        let doc = Document(title: "Route", kind: .graph, nodes: [a, b, c], groups: [whole, split])

        let clipboard = GraphClipboard(copying: [a.id, b.id], from: doc)!
        XCTAssertEqual(clipboard.groups.map(\.label), ["Both"])
    }

    func testTheClipboardsTextIsOneCardsWordsOrTheOutline() {
        let camp = graphNode("# Camp ==tonight==")
        let wood = graphNode("Firewood", parent: camp.id, x: 330)
        let doc = Document(title: "Route", kind: .graph, nodes: [camp, wood])

        XCTAssertEqual(GraphClipboard(copying: [camp.id], from: doc)?.text, "Camp tonight")
        XCTAssertEqual(GraphClipboard(copying: [camp.id, wood.id], from: doc)?.text,
                       "- # Camp ==tonight==\n  - Firewood")
    }

    func testTheClipboardRoundTripsAndRefusesAnythingElse() {
        // Whole seconds: the pasteboard's dates are ISO 8601, which keeps no fractions of one.
        let made = Date(timeIntervalSince1970: 1_785_000_000)
        let camp = GraphNode(text: "Camp", createdAt: made)
        let wood = GraphNode(text: "Firewood", parentID: camp.id, position: GraphPoint(x: 330, y: 0),
                             colorID: "amber", width: 240, createdAt: made)
        let doc = Document(title: "Route", kind: .graph, nodes: [camp, wood],
                           groups: [GraphGroup(memberIDs: [camp.id, wood.id])])
        let clipboard = GraphClipboard(copying: [camp.id, wood.id], from: doc)!

        XCTAssertEqual(GraphClipboard(data: clipboard.encoded()!), clipboard)
        XCTAssertNil(GraphClipboard(data: Data("not nodes".utf8)))
    }

    /// Every paste mints its own ids, so one copy can be pasted again and again — and the links
    /// and rings inside it follow the new ones.
    func testEachPasteMintsItsOwnIDs() {
        let camp = graphNode("Camp")
        let wood = graphNode("Firewood", parent: camp.id, x: 330, y: 20)
        let doc = Document(title: "Route", kind: .graph, nodes: [camp, wood],
                           groups: [GraphGroup(label: "Night", memberIDs: [camp.id, wood.id])])
        let clipboard = GraphClipboard(copying: [camp.id, wood.id], from: doc)!

        let first = clipboard.instantiated(offsetBy: 100, 50)
        let second = clipboard.instantiated(offsetBy: 0, 0)
        XCTAssertTrue(Set(first.map.values).isDisjoint(with: second.map.values))
        XCTAssertTrue(Set(first.map.values).isDisjoint(with: [camp.id, wood.id]))

        let pastedWood = first.nodes.first { $0.id == first.map[wood.id] }!
        XCTAssertEqual(pastedWood.parentID, first.map[camp.id])
        XCTAssertEqual(pastedWood.position, GraphPoint(x: 430, y: 70))
        XCTAssertEqual(first.groups.first?.members, Set(first.map.values))
        XCTAssertEqual(first.groups.first?.label, "Night")
    }

    /// What comes off a pasteboard is taken on trust only so far: a loop of parents is cut, and a
    /// node listed twice is pasted once.
    func testAPasteCutsALoopAndSkipsADuplicate() {
        let a = UUID(), b = UUID()
        let clipboard = GraphClipboard(nodes: [
            GraphNode(id: a, text: "A", parentID: b),
            GraphNode(id: b, text: "B", parentID: a),
            GraphNode(id: b, text: "B again", parentID: a)
        ])
        let pasted = clipboard.instantiated(offsetBy: 0, 0)
        XCTAssertEqual(pasted.nodes.count, 2)
        let graph = Document(title: "Route", kind: .graph, nodes: pasted.nodes)
        XCTAssertEqual(graph.rootNodes.count, 1)                   // one of the two was cut loose
        XCTAssertEqual(graph.nodeEntries.count, 2)                 // and the other hangs off it
    }

    @MainActor
    func testPastingIntoAnotherGraphPutsTheCopyWhereAsked() {
        let name = "GraphPasteTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let source = store.createDocument(title: "Route", kind: .graph)
        let camp = store.addRootNode(in: source.id, text: "Camp")!
        let wood = store.addChildNode(to: camp.id, in: source.id, text: "Firewood")!
        let target = store.createDocument(title: "Plan", kind: .graph)
        let clipboard = GraphClipboard(copying: [camp.id, wood.id],
                                       from: store.document(with: source.id)!)!

        let map = store.pasteNodes(clipboard, in: target.id, at: GraphPoint(x: 1000, y: 500))
        let pasted = store.document(with: target.id)!

        XCTAssertEqual(pasted.nodes.count, 2)
        let pastedCamp = pasted.node(with: map[camp.id]!)!
        let pastedWood = pasted.node(with: map[wood.id]!)!
        XCTAssertEqual(pastedWood.parentID, pastedCamp.id)
        XCTAssertEqual(pastedWood.text, "Firewood")
        // The middle of what was copied is where it was asked to go.
        XCTAssertEqual((pastedCamp.position.x + pastedWood.position.x) / 2, 1000, accuracy: 0.001)
        XCTAssertEqual(pastedCamp.position.y, 500, accuracy: 0.001)
        // And the graph it came out of is untouched.
        XCTAssertEqual(store.document(with: source.id)?.nodes.count, 2)
    }

    /// Pasted onto cards already there, the copy slides down the page until it's clear of them.
    @MainActor
    func testAPasteSlidesClearOfWhatIsAlreadyThere() {
        let name = "GraphPasteTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let graph = store.createDocument(title: "Route", kind: .graph)
        let camp = store.addRootNode(in: graph.id, text: "Camp")!
        let clipboard = GraphClipboard(copying: [camp.id], from: store.document(with: graph.id)!)!

        let map = store.pasteNodes(clipboard, in: graph.id, at: camp.position)
        let copy = store.document(with: graph.id)!.node(with: map[camp.id]!)!
        XCTAssertEqual(copy.position.x, camp.position.x, accuracy: 0.001)
        XCTAssertEqual(copy.position.y, camp.position.y + DocumentStore.standardRowStep,
                       accuracy: 0.001)
    }

    /// Paste as Child: the copied branch hangs off the card, beside it, with its shape intact.
    @MainActor
    func testPastingAsAChildHangsTheBranchOffTheCard() {
        let name = "GraphPasteTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }

        let source = store.createDocument(title: "Route", kind: .graph)
        let camp = store.addRootNode(in: source.id, text: "Camp")!
        let wood = store.addChildNode(to: camp.id, in: source.id, text: "Firewood")!
        let clipboard = GraphClipboard(copying: [camp.id, wood.id],
                                       from: store.document(with: source.id)!)!
        let target = store.createDocument(title: "Plan", kind: .graph)
        let trip = store.addRootNode(in: target.id, text: "Trip")!

        let map = store.pasteNodes(clipboard, in: target.id, under: trip.id)
        let document = store.document(with: target.id)!
        let pastedCamp = document.node(with: map[camp.id]!)!
        let pastedWood = document.node(with: map[wood.id]!)!

        XCTAssertEqual(pastedCamp.parentID, trip.id)
        XCTAssertEqual(pastedWood.parentID, pastedCamp.id)
        XCTAssertEqual(pastedCamp.position.x, trip.position.x + DocumentStore.childColumnOffset,
                       accuracy: 0.001)
        XCTAssertEqual(pastedWood.position.x - pastedCamp.position.x,
                       wood.position.x - camp.position.x, accuracy: 0.001)
    }

    // MARK: Turning a branch (Rotate ▸ Clockwise / Anticlockwise)

    func testAQuarterTurnClockwiseTakesRightToDown() {
        let pivot = GraphPoint(x: 10, y: 10)
        XCTAssertEqual(DocumentStore.quarterTurn(GraphPoint(x: 11, y: 10), about: pivot, clockwise: true),
                       GraphPoint(x: 10, y: 11))
        XCTAssertEqual(DocumentStore.quarterTurn(GraphPoint(x: 11, y: 10), about: pivot, clockwise: false),
                       GraphPoint(x: 10, y: 9))
    }

    /// Camp, with Firewood and Water in a column to its right, each with one card of its own —
    /// tidied, so the layout is the one a tidy settles on.
    @MainActor
    private func turnableGraph(in store: DocumentStore)
        -> (graph: UUID, root: UUID, first: UUID, second: UUID, grandchild: UUID) {
        let graph = store.createDocument(title: "Route", kind: .graph)
        let root = store.addRootNode(in: graph.id, text: "Camp")!
        let first = store.addChildNode(to: root.id, in: graph.id, text: "Firewood")!
        let second = store.addChildNode(to: root.id, in: graph.id, text: "Water")!
        let grandchild = store.addChildNode(to: first.id, in: graph.id, text: "By the log")!
        _ = store.addChildNode(to: second.id, in: graph.id, text: "The creek")!
        store.tidyGraph(in: graph.id)
        return (graph.id, root.id, first.id, second.id, grandchild.id)
    }

    @MainActor
    func testRotatingClockwiseTurnsARightwardBranchDownward() {
        let name = "GraphRotateTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }
        let g = turnableGraph(in: store)
        let rootBefore = store.document(with: g.graph)!.node(with: g.root)!.position

        store.rotateBranch(of: g.root, clockwise: true, in: g.graph)
        let document = store.document(with: g.graph)!
        let root = document.node(with: g.root)!
        let first = document.node(with: g.first)!
        let second = document.node(with: g.second)!

        XCTAssertEqual(root.position, rootBefore, "the pivot stays where it is")
        XCTAssertEqual(document.branchAxis(of: g.root), .down)
        XCTAssertEqual(document.branchAxis(of: g.first), .down, "the branches within turn too")
        // Tidied as a row under the pivot: level, centred, a card's width of air apart…
        XCTAssertEqual(first.position.y, second.position.y, accuracy: 0.001)
        XCTAssertEqual(first.position.y, root.position.y + 28 + 30 + 28, accuracy: 0.001)
        XCTAssertEqual((first.position.x + second.position.x) / 2, root.position.x, accuracy: 0.001)
        XCTAssertEqual(abs(first.position.x - second.position.x), 180 + 150, accuracy: 0.001)
        // …and turned, not re-ordered: the top of the column swings round to the right.
        XCTAssertGreaterThan(first.position.x, second.position.x)
        XCTAssertGreaterThan(document.node(with: g.grandchild)!.position.y, first.position.y)
    }

    @MainActor
    func testATurnAndItsOppositeComeBackToWhereTheyStarted() {
        let name = "GraphRotateTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }
        let g = turnableGraph(in: store)
        let before = store.document(with: g.graph)!.nodes

        store.rotateBranch(of: g.root, clockwise: true, in: g.graph)
        store.rotateBranch(of: g.root, clockwise: false, in: g.graph)
        assertSamePositions(store.document(with: g.graph)!.nodes, before)

        for _ in 0..<4 { store.rotateBranch(of: g.root, clockwise: true, in: g.graph) }
        assertSamePositions(store.document(with: g.graph)!.nodes, before)
    }

    /// Only what hangs off the card turns: its siblings and everything above stay put, and a card
    /// with nothing under it has nothing to turn.
    @MainActor
    func testTurningABranchLeavesTheRestOfTheGraphAlone() {
        let name = "GraphRotateTests-\(UUID().uuidString)"
        let store = DocumentStore(directoryName: name)
        defer { removeStore(named: name) }
        let g = turnableGraph(in: store)
        let before = store.document(with: g.graph)!

        store.rotateBranch(of: g.grandchild, clockwise: true, in: g.graph)
        assertSamePositions(store.document(with: g.graph)!.nodes, before.nodes)

        store.rotateBranch(of: g.first, clockwise: false, in: g.graph)
        let after = store.document(with: g.graph)!
        XCTAssertEqual(after.node(with: g.first)?.position, before.node(with: g.first)?.position)
        XCTAssertEqual(after.node(with: g.second)?.position, before.node(with: g.second)?.position)
        XCTAssertEqual(after.branchAxis(of: g.first), .up)
    }

    private func assertSamePositions(_ nodes: [GraphNode], _ expected: [GraphNode],
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(nodes.count, expected.count, file: file, line: line)
        for node in expected {
            guard let now = nodes.first(where: { $0.id == node.id }) else {
                XCTFail("\(node.text) went missing", file: file, line: line)
                continue
            }
            XCTAssertEqual(now.position.x, node.position.x, accuracy: 0.001, node.text, file: file, line: line)
            XCTAssertEqual(now.position.y, node.position.y, accuracy: 0.001, node.text, file: file, line: line)
        }
    }

    // MARK: Emoji cards

    func testASingleEmojiIsAnEmojiCard() {
        for text in ["🌲", " 🔥 ", "👍🏽", "👨‍👩‍👧", "🇳🇿", "❤️", "1️⃣"] {
            XCTAssertTrue(GraphEmoji.isSingleEmoji(text), text)
        }
        XCTAssertTrue(graphNode("⛺️").isEmojiOnly)
    }

    func testAnythingMoreThanOneEmojiIsAnOrdinaryCard() {
        // A text-style symbol, a digit, a letter, two emoji, an emoji with words, a heading.
        for text in ["", "a", "1", "©", "❤", "🌲🌲", "🌲 camp", "# 🌲"] {
            XCTAssertFalse(GraphEmoji.isSingleEmoji(text), text)
        }
    }

    // MARK: Copy ▸ As Markdown

    func testABranchCopiesAsTheOutlineFromThatNode() {
        let root = graphNode("Trip")
        let camp = graphNode("# Camp", parent: root.id, x: 330)
        let wood = graphNode("==Dry== firewood", parent: camp.id, x: 660)
        let water = graphNode("Water", parent: camp.id, x: 660, y: 90)
        let doc = Document(title: "Route", kind: .graph, nodes: [root, camp, wood, water])

        XCTAssertEqual(doc.markdown(ofBranch: camp.id), """
        - # Camp
          - ==Dry== firewood
          - Water
        """)
        // A card on its own is its words as typed, not a one-item list.
        XCTAssertEqual(doc.markdown(ofBranch: wood.id), "==Dry== firewood")
        XCTAssertEqual(doc.markdown(ofBranch: UUID()), "")
    }

    // MARK: Leaving branch isolation

    func testLeavingIsolationMovesTheRestOutByTheBranchsGrowth() {
        let before = GraphRect(minX: 0, minY: 0, maxX: 200, maxY: 100)
        // The branch grew 150 to the right and 80 downwards.
        let after = GraphRect(minX: 0, minY: 0, maxX: 350, maxY: 180)
        let right = UUID(), below = UUID(), corner = UUID(), left = UUID(), above = UUID()
        let moved = GraphArrange.makeRoom(around: before, grownTo: after, for: [
            right: GraphPoint(x: 400, y: 50),
            below: GraphPoint(x: 100, y: 300),
            corner: GraphPoint(x: 400, y: 300),
            left: GraphPoint(x: -300, y: 50),
            above: GraphPoint(x: 100, y: -200)
        ])

        XCTAssertEqual(moved[right], GraphPoint(x: 550, y: 50))
        XCTAssertEqual(moved[below], GraphPoint(x: 100, y: 380))
        XCTAssertEqual(moved[corner], GraphPoint(x: 550, y: 380))
        // Nothing grew on the left or the top, so nothing there moves.
        XCTAssertNil(moved[left])
        XCTAssertNil(moved[above])
    }

    /// Making room only ever pushes out: a branch that shrank leaves the rest where it was.
    func testLeavingIsolationNeverPullsTheRestIn() {
        let before = GraphRect(minX: 0, minY: 0, maxX: 400, maxY: 300)
        let after = GraphRect(minX: 100, minY: 50, maxX: 300, maxY: 200)
        let moved = GraphArrange.makeRoom(around: before, grownTo: after, for: [
            UUID(): GraphPoint(x: 600, y: 100),
            UUID(): GraphPoint(x: -200, y: -200)
        ])
        XCTAssertTrue(moved.isEmpty)
    }

    func testLeavingIsolationPushesLeftAndUpWhenTheBranchGrewThatWay() {
        let before = GraphRect(minX: 0, minY: 0, maxX: 200, maxY: 100)
        let after = GraphRect(minX: -120, minY: -60, maxX: 200, maxY: 100)
        let left = UUID(), above = UUID()
        let moved = GraphArrange.makeRoom(around: before, grownTo: after, for: [
            left: GraphPoint(x: -300, y: 50),
            above: GraphPoint(x: 100, y: -200)
        ])
        XCTAssertEqual(moved[left], GraphPoint(x: -420, y: 50))
        XCTAssertEqual(moved[above], GraphPoint(x: 100, y: -260))
    }

    // MARK: Pairing / subnet math

    func testIPv4RoundTrips() {
        XCTAssertEqual(NetworkInterface.ipv4ToUInt32("192.168.1.1"), 0xC0A8_0101)
        XCTAssertEqual(NetworkInterface.ipv4ToUInt32("0.0.0.0"), 0)
        XCTAssertEqual(NetworkInterface.ipv4ToUInt32("255.255.255.255"), 0xFFFF_FFFF)
        XCTAssertNil(NetworkInterface.ipv4ToUInt32("nope"))
        XCTAssertNil(NetworkInterface.ipv4ToUInt32("1.2.3"))
        XCTAssertEqual(NetworkInterface.uint32ToIPv4(0xC0A8_0101), "192.168.1.1")
    }

    func testHostsInSubnetForSlash24() {
        let hosts = NetworkInterface.hostsInSubnet(ip: "192.168.1.50", mask: "255.255.255.0")
        XCTAssertEqual(hosts.count, 254)                 // .1 … .254, excludes network + broadcast
        XCTAssertEqual(hosts.first, "192.168.1.1")
        XCTAssertEqual(hosts.last, "192.168.1.254")
        XCTAssertFalse(hosts.contains("192.168.1.0"))    // network address
        XCTAssertFalse(hosts.contains("192.168.1.255"))  // broadcast address
    }

    func testHostsInSubnetForHotspotSlash28() {
        // iOS Personal Hotspot uses 172.20.10.0/28 with the host at .1.
        let hosts = NetworkInterface.hostsInSubnet(ip: "172.20.10.2", mask: "255.255.255.240")
        XCTAssertEqual(hosts.count, 14)
        XCTAssertEqual(hosts.first, "172.20.10.1")
        XCTAssertEqual(hosts.last, "172.20.10.14")
    }

    func testHostsInSubnetIsCapped() {
        // A /16 would be 65k hosts; the cap keeps the scan bounded.
        let hosts = NetworkInterface.hostsInSubnet(ip: "10.0.0.5", mask: "255.255.0.0", cap: 256)
        XCTAssertEqual(hosts.count, 256)
    }

    // MARK: BLE framing / reassembly

    #if canImport(CoreBluetooth)
    func testReassemblerReconstructsAcrossArbitraryChunks() {
        // Two messages of different types/sizes, concatenated as they'd stream over a characteristic.
        let first = bleEnvelope(type: 0x02, body: Data("hello".utf8))
        let second = bleEnvelope(type: 0x01, body: Data((0..<1000).map { UInt8($0 % 256) }))
        var stream = first
        stream.append(second)

        var reassembler = MessageReassembler()
        var got: [(type: UInt8, body: Data)] = []
        // Feed it in awkward 7-byte chunks to exercise partial-header/partial-body handling.
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 7, stream.count)
            got += reassembler.append(stream.subdata(in: offset..<end))
            offset = end
        }

        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got.first?.type, 0x02)
        XCTAssertEqual(got.first?.body, Data("hello".utf8))
        XCTAssertEqual(got.last?.type, 0x01)
        XCTAssertEqual(got.last?.body.count, 1000)
    }

    func testReassemblerHoldsIncompleteMessage() {
        let message = bleEnvelope(type: 0x11, body: Data([1]))
        var reassembler = MessageReassembler()
        // Only the first 3 bytes (partial header) — nothing should emerge yet.
        XCTAssertTrue(reassembler.append(message.subdata(in: 0..<3)).isEmpty)
        // The remainder completes it.
        let done = reassembler.append(message.subdata(in: 3..<message.count))
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.type, 0x11)
        XCTAssertEqual(done.first?.body, Data([1]))
    }
    #endif
}
