import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth

/// Bluetooth LE transport for the direct Watch→iPad path. This is the **off-grid** option: it
/// needs no WiFi, router, or Personal Hotspot — just the two devices' Bluetooth radios.
///
/// Role split (the only one Apple supports for this pair):
///   • iPad  = BLE **peripheral** (`CBPeripheralManager`) advertising a service, hosting an RX
///     characteristic the Watch writes to and a TX characteristic it notifies on.
///   • Watch = BLE **central** (`CBCentralManager`) that scans for the service, connects, writes
///     the recording, and waits for an ack.
///
/// Throughput is modest (reliable, ordered `.withResponse` writes), which is fine for the small
/// 16 kHz mono AAC clips this app produces.
public enum WoodsWhisperBLE {
    /// Fixed 128-bit UUIDs so the Watch knows exactly what to scan/connect to (no discovery).
    public static let serviceUUID = CBUUID(string: "8C3E5B40-0E5B-4F2A-9E2A-7B1F2C9D4A10")
    /// Watch writes here (recording / pairing requests).
    public static let rxUUID = CBUUID(string: "8C3E5B41-0E5B-4F2A-9E2A-7B1F2C9D4A10")
    /// iPad notifies here (acks / pairing responses).
    public static let txUUID = CBUUID(string: "8C3E5B42-0E5B-4F2A-9E2A-7B1F2C9D4A10")
}

/// Message types in the BLE envelope. Watch→iPad use the low values; iPad→Watch use the high.
enum BLEMessageType {
    static let recording: UInt8 = 0x01       // body: [4-byte BE headerLen][header JSON][audio]
    static let pairingRequest: UInt8 = 0x02  // body: PairingRequest JSON
    static let ack: UInt8 = 0x11             // body: [1 byte] 1 = ok, 0 = rejected
    static let pairingResponse: UInt8 = 0x12 // body: PairingResponse JSON
}

/// `[1 byte type][4-byte BE length][body]`, the unit both sides chunk over the GATT characteristics.
func bleEnvelope(type: UInt8, body: Data) -> Data {
    var out = Data([type])
    out.append(bleBigEndian(UInt32(body.count)))
    out.append(body)
    return out
}

func bleBigEndian(_ value: UInt32) -> Data {
    Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
          UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
}

func bleReadBigEndian(_ data: Data) -> UInt32 {
    let b = [UInt8](data.prefix(4))
    guard b.count == 4 else { return 0 }
    return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
}

/// Reassembles a byte stream (delivered in arbitrary BLE-sized chunks) into whole
/// `[type][length][body]` messages.
struct MessageReassembler {
    private var buffer = Data()

    mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    mutating func append(_ data: Data) -> [(type: UInt8, body: Data)] {
        buffer.append(data)
        var messages: [(UInt8, Data)] = []
        var cursor = 0
        while buffer.count - cursor >= 5 {
            let base = buffer.startIndex + cursor
            let length = Int(bleReadBigEndian(buffer.subdata(in: (base + 1) ..< (base + 5))))
            let total = 5 + length
            guard buffer.count - cursor >= total else { break }
            let type = buffer[base]
            let body = buffer.subdata(in: (base + 5) ..< (base + total))
            messages.append((type, body))
            cursor += total
        }
        if cursor > 0 {
            buffer.removeSubrange(buffer.startIndex ..< (buffer.startIndex + cursor))
        }
        return messages
    }
}

// MARK: - iPad side: peripheral

// The BLE *peripheral* role (CBPeripheralManager / CBMutableService / CBMutableCharacteristic)
// is unavailable on watchOS — only iOS can advertise/host the service. The Watch is always the
// central, so this whole receiver is iOS-only.
#if os(iOS)

/// Runs on the **iPad**: advertises the Woods Whisper BLE service and receives recordings (and
/// pairing requests) from a Watch acting as central. Mirrors `LocalNetworkServer`'s contract.
public final class BluetoothRecordingServer: NSObject, RecordingReceiver {

    public var onReceive: (@MainActor (RecordingTransfer, Data) -> Void)?
    public var onPairSuccess: (@MainActor (String) -> Void)?
    /// Secret a sender must present on transfers. If nil, no auth is enforced.
    public var expectedSecret: String?

    private let serviceName: String
    private let queue = DispatchQueue(label: "WoodsWhisper.BLEServer")

    private var manager: CBPeripheralManager?
    private var txCharacteristic: CBMutableCharacteristic?
    private var subscriber: CBCentral?
    private var reassembler = MessageReassembler()
    private var outbound = Data()

    // Pairing-window state, touched only on `queue`.
    private var pairingCode: String?
    private var pairingToken: String?
    private var pairingExpiry: Date?

    public init(serviceName: String = "Woods Whisper") {
        self.serviceName = serviceName
        super.init()
    }

    public func start() throws {
        queue.async {
            guard self.manager == nil else { return }
            self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
        }
    }

    public func stop() {
        queue.async {
            self.manager?.stopAdvertising()
            self.manager?.removeAllServices()
            self.manager = nil
            self.subscriber = nil
            self.reassembler.reset()
            self.outbound.removeAll()
        }
    }

    public func beginPairing(code: String, token: String, duration: TimeInterval) {
        queue.async {
            self.pairingCode = code
            self.pairingToken = token
            self.pairingExpiry = Date().addingTimeInterval(duration)
        }
    }

    public func endPairing() {
        queue.async {
            self.pairingCode = nil
            self.pairingToken = nil
            self.pairingExpiry = nil
        }
    }

    // MARK: Inbound handling (on `queue`)

    private func handleInbound(type: UInt8, body: Data) {
        switch type {
        case BLEMessageType.recording:
            guard body.count >= 4 else { return }
            let headerLength = Int(bleReadBigEndian(body))
            guard body.count >= 4 + headerLength,
                  let transfer = try? JSONDecoder.iso.decode(
                    RecordingTransfer.self,
                    from: body.subdata(in: body.startIndex.advanced(by: 4) ..< body.startIndex.advanced(by: 4 + headerLength)))
            else { return }

            if let expected = expectedSecret, transfer.pairingSecret != expected {
                wwLog("Rejected BLE recording “\(transfer.recording.name)”: bad pairing secret", .error)
                enqueue(type: BLEMessageType.ack, body: Data([0]))
                return
            }
            let audio = body.subdata(in: body.startIndex.advanced(by: 4 + headerLength) ..< body.endIndex)
            wwLog("Incoming BLE recording “\(transfer.recording.name)” (\(audio.count) bytes)…", .transfer)
            let handler = onReceive
            Task { @MainActor in handler?(transfer, audio) }
            enqueue(type: BLEMessageType.ack, body: Data([1]))

        case BLEMessageType.pairingRequest:
            guard let request = try? JSONDecoder.iso.decode(PairingRequest.self, from: body) else { return }
            let active = pairingCode != nil
                && Date() < (pairingExpiry ?? .distantPast)
                && request.code == pairingCode
            guard active, let token = pairingToken else {
                wwLog("Rejected BLE pairing from “\(request.deviceName)”: wrong or expired code", .error)
                enqueue(type: BLEMessageType.ack, body: Data([0]))
                return
            }
            let response = PairingResponse(displayName: serviceName, token: token, port: 0)
            if let data = try? JSONEncoder.iso.encode(response) {
                enqueue(type: BLEMessageType.pairingResponse, body: data)
            }
            wwLog("Paired with Watch “\(request.deviceName)” over Bluetooth", .transfer)
            let name = request.deviceName
            let handler = onPairSuccess
            Task { @MainActor in handler?(name) }

        default:
            break
        }
    }

    // MARK: Outbound notifications (on `queue`)

    private func enqueue(type: UInt8, body: Data) {
        outbound.append(bleEnvelope(type: type, body: body))
        flushOutbound()
    }

    private func flushOutbound() {
        guard let manager, let tx = txCharacteristic, let central = subscriber else { return }
        let mtu = max(20, central.maximumUpdateValueLength)
        while !outbound.isEmpty {
            let chunk = outbound.prefix(mtu)
            if manager.updateValue(Data(chunk), for: tx, onSubscribedCentrals: [central]) {
                outbound.removeFirst(chunk.count)
            } else {
                break   // queue full; resume on peripheralManagerIsReady(toUpdateSubscribers:)
            }
        }
    }
}

extension BluetoothRecordingServer: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            wwLog("BLE peripheral not available (state \(peripheral.state.rawValue))", .transfer)
            return
        }
        let rx = CBMutableCharacteristic(type: WoodsWhisperBLE.rxUUID,
                                         properties: [.write],
                                         value: nil, permissions: [.writeable])
        let tx = CBMutableCharacteristic(type: WoodsWhisperBLE.txUUID,
                                         properties: [.notify],
                                         value: nil, permissions: [.readable])
        let service = CBMutableService(type: WoodsWhisperBLE.serviceUUID, primary: true)
        service.characteristics = [rx, tx]
        txCharacteristic = tx
        peripheral.add(service)
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [WoodsWhisperBLE.serviceUUID],
            CBAdvertisementDataLocalNameKey: serviceName
        ])
        wwLog("BLE advertising started as “\(serviceName)”", .transfer)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.value != nil {
            for message in reassembler.append(request.value!) {
                handleInbound(type: message.type, body: message.body)
            }
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        subscriber = central
        reassembler.reset()
        outbound.removeAll()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        if subscriber?.identifier == central.identifier { subscriber = nil }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushOutbound()
    }
}

#endif  // os(iOS) — peripheral role

// MARK: - Watch side: central

/// Runs on the **Watch**: sends one recording to the iPad over BLE. A fresh `BLECentralSession`
/// performs the scan → connect → write → ack round-trip.
public final class BluetoothRecordingClient: RecordingSender {

    private let link: DeviceLink
    public init(link: DeviceLink) { self.link = link }

    public var isReachable: Bool { true }   // can't cheaply probe; assume in range

    public func send(_ transfer: RecordingTransfer, audioURL: URL,
                     progress: (@Sendable (Double) -> Void)?) async throws {
        let audio = try Data(contentsOf: audioURL)
        var stamped = transfer
        stamped.pairingSecret = link.pairingSecret
        stamped.byteCount = audio.count

        let header = try JSONEncoder.iso.encode(stamped)
        var body = bleBigEndian(UInt32(header.count))
        body.append(header)
        body.append(audio)

        let outgoing = bleEnvelope(type: BLEMessageType.recording, body: body)
        let reply = try await BLECentralSession(outgoing: outgoing, progress: progress).run(timeout: 60)
        guard reply.type == BLEMessageType.ack, reply.body.first == 1 else {
            throw ConnectivityError.authenticationFailed
        }
    }
}

/// Pairs with the iPad over BLE: scan → connect → send the 5-digit code → receive the durable
/// secret. Mirrors `PairingClient.pair` but over Bluetooth, so it needs no network at all.
public enum BluetoothPairing {
    public static func pair(code: String, deviceName: String) async throws -> DeviceLink {
        let body = try JSONEncoder.iso.encode(PairingRequest(code: code, deviceName: deviceName))
        let outgoing = bleEnvelope(type: BLEMessageType.pairingRequest, body: body)
        let reply = try await BLECentralSession(outgoing: outgoing).run(timeout: 20)
        switch reply.type {
        case BLEMessageType.pairingResponse:
            guard let response = try? JSONDecoder.iso.decode(PairingResponse.self, from: reply.body) else {
                throw ConnectivityError.notReachable
            }
            return DeviceLink(transport: .bluetooth, displayName: response.displayName,
                              deviceID: response.displayName, pairingSecret: response.token)
        case BLEMessageType.ack:
            throw ConnectivityError.authenticationFailed
        default:
            throw ConnectivityError.notReachable
        }
    }
}

/// One BLE central round-trip: connect to the first Woods Whisper iPad, write `outgoing`, and
/// return the first reply message it notifies back. Bridges Core Bluetooth's delegate callbacks
/// to an async result. Retains itself for the duration (CBCentralManager holds its delegate
/// weakly), and honours Task cancellation so a racing transport can stop it promptly.
final class BLECentralSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

    struct Reply { let type: UInt8; let body: Data }

    private let outgoing: Data
    private let progress: (@Sendable (Double) -> Void)?
    private let queue = DispatchQueue(label: "WoodsWhisper.BLEClient")

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var reassembler = MessageReassembler()
    private var pendingWrite = Data()

    private var continuation: CheckedContinuation<Reply, Error>?
    private var lastReportedProgress = -1.0
    private var finished = false
    private var timeoutItem: DispatchWorkItem?
    private var selfRetain: BLECentralSession?

    init(outgoing: Data, progress: (@Sendable (Double) -> Void)? = nil) {
        self.outgoing = outgoing
        self.progress = progress
        super.init()
    }

    func run(timeout: TimeInterval) async throws -> Reply {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    self.selfRetain = self
                    let item = DispatchWorkItem { self.finish(.failure(ConnectivityError.notReachable)) }
                    self.timeoutItem = item
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: item)
                    self.manager = CBCentralManager(delegate: self, queue: self.queue)
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Reply, Error>) {
        guard !finished else { return }
        finished = true
        timeoutItem?.cancel()
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        manager?.stopScan()
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
        selfRetain = nil
    }

    // MARK: Central delegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: [WoodsWhisperBLE.serviceUUID])
        case .unauthorized, .unsupported, .poweredOff:
            finish(.failure(ConnectivityError.notAuthorized))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([WoodsWhisperBLE.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        finish(.failure(ConnectivityError.notReachable))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        finish(.failure(ConnectivityError.notReachable))
    }

    // MARK: Peripheral delegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == WoodsWhisperBLE.serviceUUID }) else {
            finish(.failure(ConnectivityError.notReachable)); return
        }
        peripheral.discoverCharacteristics([WoodsWhisperBLE.rxUUID, WoodsWhisperBLE.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == WoodsWhisperBLE.rxUUID { rxCharacteristic = characteristic }
            if characteristic.uuid == WoodsWhisperBLE.txUUID { txCharacteristic = characteristic }
        }
        guard let tx = txCharacteristic, rxCharacteristic != nil else {
            finish(.failure(ConnectivityError.notReachable)); return
        }
        peripheral.setNotifyValue(true, for: tx)   // subscribe before writing so we catch the ack
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == WoodsWhisperBLE.txUUID, error == nil else { return }
        pendingWrite = outgoing
        writeNextChunk()
    }

    private func writeNextChunk() {
        guard let peripheral, let rx = rxCharacteristic, !pendingWrite.isEmpty else { return }
        let mtu = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        let chunk = pendingWrite.prefix(mtu)
        pendingWrite.removeFirst(chunk.count)
        peripheral.writeValue(Data(chunk), for: rx, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error { finish(.failure(ConnectivityError.transportFailure(error))); return }
        if let progress, outgoing.count > 0 {
            let fraction = min(1, Double(outgoing.count - pendingWrite.count) / Double(outgoing.count))
            if fraction - lastReportedProgress >= 0.01 || fraction >= 1 {   // throttle to ~1% steps
                lastReportedProgress = fraction
                progress(fraction)
            }
        }
        if !pendingWrite.isEmpty { writeNextChunk() }   // else: done writing, await the TX reply
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == WoodsWhisperBLE.txUUID, let value = characteristic.value else { return }
        for message in reassembler.append(value) {
            finish(.success(Reply(type: message.type, body: message.body)))
            return
        }
    }
}
#endif
