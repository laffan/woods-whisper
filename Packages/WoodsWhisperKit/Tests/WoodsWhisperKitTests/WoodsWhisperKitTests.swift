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

    func testLanguageModelDefaultIsGemma3_4B() {
        XCTAssertEqual(LanguageModelChoice.default, .gemma3_4B)
    }

    func testLanguageModelLineupDropsGemma12B() {
        let ids = LanguageModelChoice.allCases.map(\.rawValue)
        XCTAssertTrue(ids.contains("mlx-community/Qwen3-4B-4bit"))
        XCTAssertTrue(ids.contains("mlx-community/Llama-3.2-3B-Instruct-4bit"))
        XCTAssertFalse(ids.contains { $0.contains("12b") })
    }

    func testEveryOnDeviceModelHasStopSequences() {
        // Local models need explicit turn-end markers; online ones let the API signal end-of-turn.
        let local = LanguageModelChoice.allCases.filter { !$0.isOnline }
        XCTAssertTrue(local.allSatisfy { !$0.stopSequences.isEmpty })
        XCTAssertTrue(LanguageModelChoice.claudeSonnet.stopSequences.isEmpty)
    }

    func testOnlyQwen3UsesThinkTags() {
        XCTAssertTrue(LanguageModelChoice.qwen3_4B.usesThinkTags)
        XCTAssertFalse(LanguageModelChoice.gemma3_4B.usesThinkTags)
        XCTAssertFalse(LanguageModelChoice.llama3_2_3B.usesThinkTags)
        XCTAssertFalse(LanguageModelChoice.claudeSonnet.usesThinkTags)
    }

    func testOnlyClaudeModelsAreOnline() {
        XCTAssertTrue(LanguageModelChoice.claudeSonnet.isOnline)
        XCTAssertTrue(LanguageModelChoice.claudeHaiku.isOnline)
        XCTAssertFalse(LanguageModelChoice.gemma3_4B.isOnline)
        XCTAssertFalse(LanguageModelChoice.qwen3_4B.isOnline)
    }

    func testOnlineModelsUseApiModelIDAsRawValue() {
        XCTAssertEqual(LanguageModelChoice.claudeSonnet.rawValue, "claude-sonnet-4-6")
        XCTAssertEqual(LanguageModelChoice.claudeHaiku.rawValue, "claude-haiku-4-5")
    }

    func testShortNamesAreConcise() {
        XCTAssertEqual(LanguageModelChoice.claudeHaiku.shortName, "Haiku 4.5")
        XCTAssertEqual(LanguageModelChoice.gemma3_4B.shortName, "Gemma 3 4B")
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
