import XCTest
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
        XCTAssertTrue(GraphArrange.alignTop([box(0, 0)]).isEmpty)
    }

    /// Nothing to do is nothing done — a no-op arrangement doesn't move (or re-save) a single card.
    func testArrangingWhatIsAlreadyArrangedMovesNothing() {
        let column = [box(0, 0), box(0, 200), box(0, 400)]
        XCTAssertTrue(GraphArrange.alignLeft(column).isEmpty)
        XCTAssertTrue(GraphArrange.distributeVertically(column).isEmpty)
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
