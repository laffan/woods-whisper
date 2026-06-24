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

    func testEveryLanguageModelHasStopSequences() {
        XCTAssertTrue(LanguageModelChoice.allCases.allSatisfy { !$0.stopSequences.isEmpty })
    }

    func testOnlyQwen3UsesThinkTags() {
        XCTAssertTrue(LanguageModelChoice.qwen3_4B.usesThinkTags)
        XCTAssertFalse(LanguageModelChoice.gemma3_4B.usesThinkTags)
        XCTAssertFalse(LanguageModelChoice.llama3_2_3B.usesThinkTags)
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
