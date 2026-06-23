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

On the phone/iPad, open **Settings**. There are two model sections, each with its own
**Download** button and a progress bar that shows megabytes downloaded over the total:

- **Speech Model** — Parakeet TDT v3 (~a few hundred MB) via FluidAudio.
- **Language Model** — Gemma 3 4B (default; ~2.5–3 GB quantized) via MLX. Pick a different
  size in the same section first if you want 1B (smaller/faster) or 12B (high-RAM devices
  only), then tap Download. Switching size requires downloading that model.

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
See **`docs/CONNECTIVITY.md`** for the full walkthrough. In short:

1. On the **iPad**: Settings → enable *"Receive directly from Watch (no phone)"* → open
   *"Watch Pairing Details"*. Note the **WiFi address**, **port**, and **pairing secret**
   (also shown as a QR code).
2. On the **Watch**: switch the transport to *local network* and enter those values.
3. Make sure both devices are on the **same WiFi** network. A DHCP reservation for the iPad
   keeps the address stable.

## Troubleshooting

- **"Model isn't ready"** — re-tap the model's **Download** button in Settings while online.
- **Download stuck at 0%** — open the **Log** tab. It records when each download starts, byte
  progress, a warning if no progress arrives for ~20s (slow/stalled connection), and the
  underlying connection error if one occurs. Copy the log to diagnose.
- **API mismatch when building** — the FluidAudio / MLX SDKs changed; adjust the lines marked
  `(1)/(2)/(3)` in `ParakeetTranscriptionService.swift` / `GemmaTransformService.swift`.
- **Watch can't reach iPad** — confirm same WiFi, correct IP (it changes without a DHCP
  reservation), and that the iPad app is foregrounded with the server enabled.
