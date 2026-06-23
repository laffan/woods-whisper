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

2. **Watch → iPad with no phone in the loop.** Achievable, with one compromise. watchOS blocks
   general Bonjour browsing, but an *independent* watchOS app **can** use the network over a
   known WiFi network even without its paired iPhone. So:
   - the **iPad** runs a small local server (`LocalNetworkServer`, `NWListener`),
   - the **Watch** sends recordings to it (`LocalNetworkClient`, `NWConnection`),
   - because the Watch can't auto-discover the iPad, you pair them **once** with a 5-digit code:
     the iPad shows it (Settings → *Pair Watch*), you type it on the Watch, and the Watch finds
     the iPad on the network itself. Works over WiFi *or* the iPad's Personal Hotspot when there's
     no WiFi at all. See `docs/CONNECTIVITY.md`.

   The standard **Watch → iPhone** path uses WatchConnectivity and needs no configuration.

## Building

This repo contains source only — no checked-in `.xcodeproj` (it's generated). On a Mac with
Xcode 15+:

```bash
brew install xcodegen          # one-time
cd woods-whisper
xcodegen generate              # creates WoodsWhisper.xcodeproj
open WoodsWhisper.xcodeproj
```

Then in Xcode: select the **WoodsWhisper** scheme, set your signing team, and run on a device
(the ML models need real hardware; the Simulator can't use the ANE).

> ⚠️ **The Swift package versions for FluidAudio and MLX move quickly.** Two files —
> `ParakeetTranscriptionService.swift` and `GemmaTransformService.swift` — call those SDKs and
> have their version-sensitive lines marked `(1)/(2)/(3)`. If Xcode flags an API mismatch after
> resolving packages, adjust those lines; nothing else in the app depends on the SDK surface.

First launch: open **Settings → Download / Prepare Models** while online once.

See **`docs/SETUP.md`** for the full first-run walkthrough and **`docs/ARCHITECTURE.md`** for
how the pieces fit together.

## Models

| Role          | Model                         | Package    | Runs on            |
|---------------|-------------------------------|------------|--------------------|
| Speech → text | Parakeet TDT 0.6b **v3**      | FluidAudio | iPhone / iPad (ANE)|
| Text rewrite  | **Gemma 3** 4B (default)      | MLX Swift  | iPhone / iPad      |
|               | Gemma 3 1B / 12B (selectable) |            |                    |

There is no "Gemma 4"; the current line is Gemma 3 (1B/4B/12B/27B). The default is **4B** for
broad device support; **12B** is selectable on high-RAM devices (iPad Pro M-series, iPhone Pro
8 GB+). Change it in **Settings → Language Model**.
