# Connectivity: how recordings move between devices

There are three transports. The app picks one per the Watch's `transport` setting.

| Transport      | Watch → … | Needs | Speed | Where used |
|----------------|-----------|-------|-------|------------|
| `phoneSession` | paired iPhone (WCSession) | nothing | fast | default with an iPhone |
| `localNetwork` | iPad over WiFi | a shared WiFi/LAN | fast | home / any network |
| `bluetooth`    | iPad over BLE | nothing but the two radios | modest | **off-grid, no WiFi** |

Pairing a Watch directly to an iPad **races `localNetwork` and `bluetooth`** — you type one code
and whichever answers first is saved. So it "just works" on WiFi *and* with no network at all.

## 1. Watch → iPhone (WatchConnectivity)

The supported, reliable default. `PhoneSessionTransport` wraps `WCSession`:

- **Watch** calls `transferFile(_:metadata:)` — the system queues and retries even if the iPhone
  app is backgrounded or the devices are briefly apart.
- **iPhone** receives in `session(_:didReceive:)`, decodes the `RecordingTransfer` metadata, and
  hands the bytes to `RecordingStore`.

`WCSession` only ever talks to the Watch's **paired iPhone** — it cannot target an iPad. That's
why the second transport exists.

## 2. Watch → iPad (local network, no phone)

### Why this is possible
An *independent* watchOS app can use the network over a **known WiFi network** even when its
paired iPhone is absent. What it **cannot** do is browse Bonjour to discover peers. So we make
the iPad a server with a known address and have the Watch dial it directly.

### Pairing with a 5-digit code (no IP to type, no QR to scan)
No Bonjour browsing on watchOS ⇒ the Watch can't auto-find the iPad, and a Watch can neither scan
a QR nor have you comfortably type an IP and a UUID. So pairing works the other way around:

1. On the **iPad** (Settings → *Receive directly from Watch* → **Pair Watch** → *Start Pairing*),
   a random **5-digit code** is shown for ~2 minutes. The iPad's local server enters a pairing
   window that will accept that code.
2. On the **Watch** (Settings → **Pair with iPad**), you type those 5 digits.
3. The Watch **finds the iPad itself**: it sweeps the local subnet (gateway/hotspot addresses
   first, then the full range) on the well-known port and offers the code to each host. The iPad
   that's in pairing mode validates the code and replies with its name, port, and the durable
   `pairingSecret`. The Watch saves all of that as a `DeviceLink`.

From then on it's automatic — the Watch dials the saved `host:port` and stamps the saved secret
on every transfer. The 5-digit code is only ever used during that short pairing window.

The fixed port is `LocalNetworkDefaults.port` (50710) so the Watch knows where to knock.

### Wire protocol
TCP via the `Network` framework. Every frame starts with a 1-byte **message type**:

```
recording (0x01):
  [0x01]
  [4 bytes big-endian: headerLength]
  [headerLength bytes : JSON RecordingTransfer]   ← metadata + byteCount + pairingSecret
  [byteCount bytes     : audio (.m4a)]
  → server replies [1 byte: 0x01 accepted / 0x00 rejected]

pairing (0x02):
  [0x02]
  [4 bytes big-endian: reqLength]
  [reqLength bytes : JSON PairingRequest]          ← 5-digit code + Watch name
  → server replies [1 byte ack][4 bytes big-endian respLength][JSON PairingResponse]
                                                     ← iPad name + durable token + port
```

- **iPad** — `LocalNetworkServer` (`NWListener`). For transfers, validates `pairingSecret` and
  persists the audio. For pairing, checks the code against the open window and hands back the
  durable secret. Also advertises `_woodswhisper._tcp` via Bonjour so iPad/iPhone peers that
  *can* browse may discover it (the Watch ignores this and dials direct).
- **Watch** — `LocalNetworkClient` sends recordings; `PairingClient` runs the subnet scan during
  pairing. Both via `NWConnection`.

### Security
The `pairingSecret` (a UUID generated on the iPad at first run) gates writes, so a random device
on the WiFi can't push recordings to your iPad. The Watch only learns it by presenting the
short-lived 5-digit code during the pairing window. This is a **personal, sideloaded app**, so
the threat model is deliberately light; everything stays on the LAN and nothing leaves it.

## 3. Watch → iPad over Bluetooth (off-grid, no WiFi at all)

This is the answer for the woods: no router, no signal, and a **WiFi-only iPad** (which can't
create a Personal Hotspot — that needs cellular, and there's no public API to make an iPad a WiFi
access point). The only Apple-supported way to move app data between *these two* devices with no
network is **Bluetooth LE** via Core Bluetooth, which both watchOS and iOS support.

### Role split (the only one that works for this pair)
- **iPad** = BLE **peripheral** (`BluetoothRecordingServer` / `CBPeripheralManager`): advertises
  the `WoodsWhisperBLE` service, hosts an **RX** characteristic the Watch writes to and a **TX**
  characteristic it notifies on.
- **Watch** = BLE **central** (`BluetoothRecordingClient` / `CBCentralManager`): scans for the
  service, connects, writes the recording, waits for an ack. (Multipeer Connectivity and
  `WCSession` aren't options — the former isn't on watchOS, the latter only targets the paired
  iPhone. Core Bluetooth is.)

### Wire format over GATT
The same logical envelope as the WiFi path — `[1-byte type][4-byte BE length][body]` — but
chunked across the characteristic (each side reassembles with `MessageReassembler`). Writes use
`.withResponse` for reliable, ordered delivery; the iPad replies with an `ack` (or a
`PairingResponse` during pairing) as a TX notification.

### Throughput
Modest by design — reliable chunked writes run at roughly a connection-interval per chunk. That's
fine for this app's small **16 kHz mono AAC** clips (a short whisper is tens of KB → a few
seconds; a minute-plus clip takes longer). For bulk transfer use WiFi when a network exists.
Because it's chunked, the Watch shows a real **upload progress bar** (the BLE sender reports
`bytesSent / total` via the `RecordingSender` progress callback); the WiFi/WCSession paths send in
one shot and just show a spinner.

### Pairing is unified
You don't choose Bluetooth vs WiFi up front. Enter the 5-digit code once and the Watch races a
WiFi subnet scan and a BLE scan; the first to validate the code wins and its transport is saved in
the `DeviceLink`. Off-grid, WiFi fails fast (no shared subnet) and Bluetooth wins.

### Practical tips
- Keep the two devices **close** during pairing and transfer (BLE range).
- Keep the **iPad app foregrounded** — advertising and receiving are most reliable in the
  foreground (the iPad also keeps a `bluetooth-peripheral` background mode as a fallback).
- First use prompts for **Bluetooth** permission on both devices — allow it.

## Limits / honest caveats

- With a WiFi-only iPad and no router, **Bluetooth is the only software path** — there's no way to
  put the two on a shared IP network without extra hardware (a battery travel router) or a
  cellular iPad's Personal Hotspot.
- BLE is **slower** than WiFi; it's meant for short field clips, not bulk sync.
- If the iPad's WiFi IP changes (no DHCP reservation) on the `localNetwork` path, just re-pair —
  tap **Pair Watch** on the iPad and re-enter the new 5-digit code on the Watch.
- This needs a **personal/sideloaded build**; the manual pairing UX wouldn't pass App Review,
  but that's irrelevant here. It uses only public APIs (no private/entitlement tricks), so it
  works on a normal developer-signed install.
