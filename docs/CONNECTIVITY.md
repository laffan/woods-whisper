# Connectivity: how recordings move between devices

There are two transports. The app picks one per the Watch's `transport` setting.

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

### Working with no WiFi at all (off-grid)
The Watch finds the iPad by scanning whatever subnet the two devices share — it doesn't care
*how* that link exists. So in the woods, with no router and no signal:

- Turn on the iPad's **Personal Hotspot** (needs a cellular iPad; the hotspot's WiFi radio comes
  up and provides a local network even with no upstream internet). Join it from the Watch.
- The iPad is the hotspot gateway (`172.20.10.1`), which the scan tries **first**, so pairing and
  every later transfer are fast.
- A WiFi-only iPad can't create an access point (no public API for that). For that case bring a
  tiny battery travel router, or use a cellular iPad.

### Practical tips
- Same network on both devices (shared WiFi, or the iPad's hotspot).
- On a home network, a **DHCP reservation** keeps the iPad's address stable (re-pairing is cheap
  regardless — it's just the 5-digit code again).
- Keep the iPad app foregrounded when sending; background networking on iPad is best-effort.

## Limits / honest caveats

- There is **no** Apple-sanctioned way for the Watch to send straight to an iPad *without* a
  shared IP network (e.g. pure Bluetooth) — `WCSession` and Multipeer Connectivity aren't
  available for that pair. The off-grid answer is the iPad's Personal Hotspot (see above).
- If the iPad's IP changes and there's no reservation, just re-pair — tap **Pair Watch** on the
  iPad and re-enter the new 5-digit code on the Watch.
- This needs a **personal/sideloaded build**; the manual pairing UX wouldn't pass App Review,
  but that's irrelevant here. It uses only public APIs (no private/entitlement tricks), so it
  works on a normal developer-signed install.
