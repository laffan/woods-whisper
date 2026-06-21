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

### Why there's a one-time manual step
No Bonjour browsing on watchOS ⇒ the Watch can't auto-find the iPad. You give the Watch the
iPad's `host` + `port` + `pairingSecret` once (typed, or via the QR shown on the iPad). After
that it's automatic on the same network.

### Wire protocol
TCP via the `Network` framework, length-prefixed framing:

```
[4 bytes big-endian: headerLength]
[headerLength bytes : JSON RecordingTransfer]   ← recording metadata + byteCount + pairingSecret
[byteCount bytes     : audio (.m4a)]
[server replies 1 byte: 0x01 accepted / 0x00 rejected]
```

- **iPad** — `LocalNetworkServer` (`NWListener`). Validates `pairingSecret` against the value
  from setup (rejects strangers on the LAN), writes the audio, and persists the recording.
  Also advertises `_woodswhisper._tcp` via Bonjour so iPad/iPhone peers that *can* browse may
  discover it (the Watch ignores this and dials direct).
- **Watch** — `LocalNetworkClient` (`NWConnection`). Reads the audio, stamps the secret, frames
  the message, sends, and waits for the ack.

### Security
The `pairingSecret` (a UUID generated on the iPad at first run) gates writes, so a random device
on the WiFi can't push recordings to your iPad. Everything stays on the LAN; nothing leaves it.

### Practical tips
- Same WiFi network on both devices.
- Give the iPad a **DHCP reservation** so its address doesn't change.
- Keep the iPad app foregrounded when sending; background networking on iPad is best-effort.

## Limits / honest caveats

- There is **no** Apple-sanctioned way for the Watch to send straight to an iPad *without* WiFi
  (e.g. pure Bluetooth) — `WCSession` and Multipeer Connectivity aren't available for that pair.
- If the iPad's IP changes and there's no reservation, re-pair from **Watch Pairing Details**.
- This needs a **personal/sideloaded build**; the manual pairing UX wouldn't pass App Review,
  but that's irrelevant here. It uses only public APIs (no private/entitlement tricks), so it
  works on a normal developer-signed install.
