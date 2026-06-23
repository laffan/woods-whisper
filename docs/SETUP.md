# First-run setup

Everything below the "while online once" step happens **offline** afterward.

## 1. Generate and open the project

```bash
brew install xcodegen        # one-time
xcodegen generate
open WoodsWhisper.xcodeproj
```

Set your **signing team** on both the `WoodsWhisper` and `WoodsWhisperWatch` targets
(Signing & Capabilities).

## 2. Run on real hardware

The ANE/CoreML and MLX paths need a physical device. Build the **WoodsWhisper** scheme to an
iPhone or iPad. The watch app installs alongside it; you can also run the watch scheme directly.

## 3. Download the models (online, once)

On the phone/iPad: **Settings → Download / Prepare Models**.

- **Parakeet TDT v3** (~a few hundred MB) via FluidAudio.
- **Gemma 3 4B** (default; ~2.5–3 GB quantized) via MLX. Pick a different size first under
  **Settings → Language Model** if you want 1B (smaller/faster) or 12B (high-RAM devices only).

Both load from local cache after this — no further network use.

> If you only ever use an iPad standalone (no Watch, no phone), this is all you need: record on
> the iPad, transcribe, and transform.

## 4. Microphone permission

First record triggers the mic prompt on each device. Allow it.

## 5. Pairing the Watch

### A. Watch → iPhone (default, zero config)
If your Watch is paired to the iPhone running the app, nothing to do. Recordings transfer over
WatchConnectivity automatically (even when the phone is backgrounded).

### B. Watch → iPad directly (no phone)
Pairing is a 5-digit code — no IP to type, no QR (a Watch can't scan one anyway). See
**`docs/CONNECTIVITY.md`** for how it works. In short:

1. On the **iPad**: Settings → enable *"Receive directly from Watch (no phone)"* → tap
   **Pair Watch** → **Start Pairing**. A 5-digit code appears for ~2 minutes.
2. On the **Watch**: open Woods Whisper → swipe to **Settings** → **Pair with iPad** → type the
   5 digits. The Watch finds the iPad on the network by itself and confirms when paired.
3. No WiFi needed. Pairing connects over **WiFi** if both devices share a network, otherwise over
   **Bluetooth** — so it works off-grid in the woods with a WiFi-only iPad. Keep the two devices
   close, and keep the iPad app foregrounded.

> The first time, the Watch asks for **Local Network** and/or **Bluetooth** permission — allow
> them, or it can't see the iPad. Bluetooth transfers are slower than WiFi but need no network.

## Troubleshooting

- **"Model isn't ready"** — re-run *Download / Prepare Models* while online.
- **API mismatch when building** — the FluidAudio / MLX SDKs changed; adjust the lines marked
  `(1)/(2)/(3)` in `ParakeetTranscriptionService.swift` / `GemmaTransformService.swift`.
- **Watch can't reach iPad** — confirm the iPad app is foregrounded with *Receive directly from
  Watch* enabled, the devices are close (for Bluetooth), and the Watch was granted Local Network
  and Bluetooth permission. If pairing times out, tap **Pair Watch** again for a fresh code.
