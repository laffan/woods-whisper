# Woods Whisper

Offline voice capture, transcription, and text transformation for **iOS / iPadOS / watchOS**.

Record audio on your Apple Watch or your iPhone/iPad, transcribe it to text **entirely
on-device** with NVIDIA **Parakeet TDT v3** (via CoreML/ANE), then reshape that text with a
lightweight on-device **Gemma 3** model driven by reusable prompt presets.

> **No internet required after first-run setup.** The only time the network is used is to
> download the two models once. Everything after that — recording, transfer, transcription,
> and transformation — happens locally.

---

## What's here

```
woods-whisper/
├── project.yml                      # XcodeGen spec → generates WoodsWhisper.xcodeproj
├── Packages/WoodsWhisperKit/        # Shared Swift package (models, audio, storage,
│   └── Sources/WoodsWhisperKit/     #   transcription, transform, connectivity)
├── Apps/iOS/                        # iOS / iPadOS app (Recordings, Documents, Settings)
├── Apps/Watch/                      # watchOS app (record button + recordings list)
└── docs/                            # ARCHITECTURE.md, SETUP.md, CONNECTIVITY.md
```

The app code is split so the **Watch never links the ML dependencies** — transcription and the
LLM run only on iOS/iPadOS, behind protocols (`TranscriptionService`, `TextTransformService`)
the rest of the app depends on.

## The two hard requirements, and how they're met

1. **Fully offline.** Parakeet runs via [FluidAudio](https://github.com/FluidInference/FluidAudio)
   (CoreML/ANE); Gemma 3 runs via [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm).
   Both download once during setup and load from local cache forever after. No telemetry, no
   cloud calls in the recording/transcription/transformation paths.

2. **Watch → iPad with no phone in the loop — and no WiFi either.** Two direct transports cover
   both cases. On a shared network the Watch uses WiFi; with *nothing* but the two devices it
   falls back to Bluetooth (the off-grid woods case, including a WiFi-only iPad). So:
   - the **iPad** runs a local WiFi server (`LocalNetworkServer`, `NWListener`) **and** advertises
     over Bluetooth (`BluetoothRecordingServer`, `CBPeripheralManager`),
   - the **Watch** sends over WiFi (`LocalNetworkClient`, `NWConnection`) or Bluetooth
     (`BluetoothRecordingClient`, `CBCentralManager`),
   - you pair them **once** with a 5-digit code: the iPad shows it (Settings → *Pair Watch*), you
     type it on the Watch, and the Watch finds the iPad itself. Pairing **races WiFi and
     Bluetooth** — over WiFi when both share a network, or **Bluetooth (`CBPeripheralManager` on
     the iPad, `CBCentralManager` on the Watch) when there's no WiFi at all**, so it works
     off-grid even with a WiFi-only iPad. See `docs/CONNECTIVITY.md`.

   The standard **Watch → iPhone** path uses WatchConnectivity and needs no configuration.

## Building

This repo contains source only — no checked-in `.xcodeproj` (it's generated). On a Mac with
Xcode 15+:

```bash
brew install xcodegen          # one-time
cd woods-whisper
./Scripts/generate.sh          # auto-detects your signing team, creates WoodsWhisper.xcodeproj
open WoodsWhisper.xcodeproj
```

`Scripts/generate.sh` finds your Apple **Team ID** and applies it — plus a **unique bundle-ID
prefix** — to **every** target (app, watch app, and the two extensions), so signing "just works"
and the new App IDs don't collide with the generic `com.woodswhisper.*` identifiers (already
registered to someone else). By default it derives a unique prefix from your team; pass your own for
a prettier one:

```bash
./Scripts/generate.sh A1B2C3D4E5 com.yourname   # explicit Team ID + bundle prefix
```

Equivalent via env: `DEVELOPMENT_TEAM=… BUNDLE_ID_PREFIX=com.yourname xcodegen generate`. Keep the
**same** prefix across runs so you don't create a fresh batch of App IDs each time — free Apple IDs
cap App IDs at ~10 per 7 days.

Then in Xcode: select the **WoodsWhisper** scheme, set your signing team, and run on a device
(the ML models need real hardware; the Simulator can't use the ANE).

> **Widget/Control & complication targets.** The project includes two WidgetKit app extensions —
> `WoodsWhisperWidgets` (iOS Lock Screen widget + iOS 18 Control for "New Recording") and
> `WoodsWhisperWatchComplication` (a watch complication). After pulling, **re-run
> `./Scripts/generate.sh`** so they're added and signed with your team automatically. A **free**
> Apple ID works — complications/widgets need no paid membership. The iOS **Control** appears on
> iOS 18+; the Lock Screen widget works on iOS 17. Both start a recording by opening the app via the
> `woodswhisper://record` deep link / the shared `StartRecordingIntent`.

> ⚠️ **The Swift package versions for FluidAudio, WhisperKit, and MLX move quickly.** Three
> files — `ParakeetTranscriptionService.swift`, `WhisperTranscriptionService.swift`, and
> `GemmaTransformService.swift` — call those SDKs and have their version-sensitive lines marked
> `(1)/(2)/(3)`. If Xcode flags an API mismatch after resolving packages, adjust those lines;
> nothing else in the app depends on the SDK surface.

First launch: open **Settings** while online once and tap **Download** under both the
**Speech Model** and **Language Model** sections.

See **`docs/SETUP.md`** for the full first-run walkthrough and **`docs/ARCHITECTURE.md`** for
how the pieces fit together.

## Models

| Role          | Model                         | Package    | Runs on            |
|---------------|-------------------------------|------------|--------------------|
| Speech → text | Parakeet TDT 0.6b **v3** (default) | FluidAudio | iPhone / iPad (ANE)|
|               | Whisper tiny / base / small (selectable) | WhisperKit | iPhone / iPad |
| Text rewrite  | **Gemma 3 4B** (default)      | MLX Swift  | iPhone / iPad      |
|               | Qwen3 4B / Llama 3.2 3B / Gemma 3 1B (selectable) | |            |

**Speech model.** Parakeet TDT v3 is the default — most accurate and multilingual. The smaller
**Whisper** variants (tiny/base/small) are lighter, faster downloads; pick one in
**Settings → Speech Model** if you prefer Whisper or want a smaller footprint.

**Language model.** The default is **Gemma 3 4B**; **Qwen3 4B**, **Llama 3.2 3B**, and **Gemma 3
1B** are selectable alternatives, all 4-bit quantized via MLX. Change it in **Settings → Language
Model**. Each downloads once while online and is reloaded automatically from cache on subsequent
launches (no need to re-tap Download). **Qwen3 4B** is a "thinking" model — its reasoning is shown
in a collapsible **Reasoning** section above each result and kept out of the saved output.
