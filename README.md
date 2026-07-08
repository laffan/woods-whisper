# Woods Whisper

Offline voice capture, transcription, and text transformation for **iOS / iPadOS / watchOS**.

Record audio on your Apple Watch or your iPhone/iPad, transcribe it to text **entirely
on-device** with NVIDIA **Parakeet TDT v3** (via CoreML/ANE), then reshape that text with a
lightweight on-device **Gemma 3** model driven by reusable prompt presets.

> **No internet required after first-run setup.** The only time the network is used is to
> download the two models once. Everything after that — recording, transfer, transcription,
> and transformation — happens locally. (Optionally, when you have a signal, you can pick an
> online **Claude** model for the rewrite step — see *Models* below — but the on-device models
> remain the default and the offline path is unchanged.)

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

## Capturing and organizing

- **Inbox is its own tab.** Watch clips and one-tap "New Recording" captures land in the **Inbox**,
  now the first top-level section (ahead of Documents) rather than a row inside the documents list.
- **Record straight to a document from the Watch.** The iPhone syncs your document list to the Watch
  over WatchConnectivity; swipe left on the Watch's record screen to pick a target document (or the
  Inbox). The chosen target's name shows on the record screen, and clips captured there are filed into
  that document on the iPhone/iPad instead of the Inbox. (Targets sync over the paired-iPhone path; the
  direct-to-iPad transports still file into the Inbox.)
- **Pin documents.** Swipe a document and tap **Pin** to hold it at the top of the list.
- **Insert while editing.** The paragraph editor has an **Insert** button that records a clip,
  transcribes it, and splices the text in at the cursor — the clip is saved with the document's other
  recordings.
- **Find & replace.** The whole-document editor has a find/replace bar at the bottom (the magnifying
  glass in the editor's toolbar) — search, step through matches, and Replace / Replace All.
- **Share a whole document as a file.** From a document's overflow menu, **Share as Woods Whisper
  File** exports a single `.wwdoc` file bundling the audio *and* the current edited transcriptions.
  Send it to another device (AirDrop, Files, Messages…) and open it there to rebuild the document —
  no network round-trip. Woods Whisper registers `.wwdoc` so it can both create and receive them.
- **Share audio in.** Send an audio file to Woods Whisper from the iOS share sheet / "Open in…"; it's
  imported into the Inbox and transcribed like any other recording.
- **Number Paragraphs.** A built-in transform that numbers the paragraphs (applied locally, so it needs
  no language model).

## Building

This repo contains source only — no checked-in `.xcodeproj` (it's generated). On a Mac with
Xcode 15+:

```bash
brew install xcodegen          # one-time
cd woods-whisper
xcodegen generate              # creates WoodsWhisper.xcodeproj
open WoodsWhisper.xcodeproj
```

Then in Xcode: select the **WoodsWhisper** scheme (or **WoodsWhisperWatch** to run on the Watch
directly), set your signing team on each target, and run on a device (the ML models need real
hardware; the Simulator can't use the ANE).

> **"New Recording" everywhere.** A `StartRecordingIntent` App Intent (in `WoodsWhisperKit`) lets you
> start a recording from **Siri, Spotlight, Shortcuts, the iOS Action Button, and a Lock Screen /
> Control Center Shortcut** — no extra target or paid account needed.
>
> **Native watch complication (built in).** A bespoke WidgetKit complication (`Apps/WatchComplication`)
> puts a **New Recording** button on the watch face; tapping it opens the app via the
> `woodswhisper://record` deep link and starts capturing. It's a watchOS `app-extension` target
> embedded in the watch app, so it builds with the default scheme (give it a signing team alongside the
> other targets).
>
> **iOS Lock Screen widget / Control (optional).** A separate WidgetKit extension for an iOS Lock
> Screen widget + iOS 18 Control (`Apps/iOSWidgets`) is in the repo but **not built by default** —
> provisioning its extra app-extension App ID is painful on a free Apple ID. To enable it, re-add a
> `WoodsWhisperWidgets` `app-extension` target to `project.yml` (see this file's git history), embed it
> in the iOS app, and give it a signing team.

> ⚠️ **The Swift package versions for FluidAudio, WhisperKit, and MLX move quickly.** Three
> files — `ParakeetTranscriptionService.swift`, `WhisperTranscriptionService.swift`, and
> `GemmaTransformService.swift` — call those SDKs and have their version-sensitive lines marked
> `(1)/(2)/(3)`. If Xcode flags an API mismatch after resolving packages, adjust those lines;
> nothing else in the app depends on the SDK surface.

First launch: open **Settings** while online once and tap **Download** under both the
**Speech Model** and **Language Model** sections. (If you pick one of the online Claude models for
the Language Model, tap **Authenticate** and paste your Anthropic API key instead of downloading.)

See **`docs/SETUP.md`** for the full first-run walkthrough and **`docs/ARCHITECTURE.md`** for
how the pieces fit together.

## Models

| Role          | Model                         | Package    | Runs on            |
|---------------|-------------------------------|------------|--------------------|
| Speech → text | Parakeet TDT 0.6b **v3** (default) | FluidAudio | iPhone / iPad (ANE)|
|               | Whisper tiny / base / small (selectable) | WhisperKit | iPhone / iPad |
| Text rewrite  | **Gemma 3 4B** (default)      | MLX Swift  | iPhone / iPad      |
|               | Qwen3 4B / Llama 3.2 3B / Gemma 3 1B (selectable) | |            |
|               | Claude Sonnet 4.6 / Haiku 4.5 (online, selectable) | Anthropic API | cloud (needs signal) |

**Speech model.** Parakeet TDT v3 is the default — most accurate and multilingual. The smaller
**Whisper** variants (tiny/base/small) are lighter, faster downloads; pick one in
**Settings → Speech Model** if you prefer Whisper or want a smaller footprint.

**Language model.** The default is **Gemma 3 4B**; **Qwen3 4B**, **Llama 3.2 3B**, and **Gemma 3
1B** are selectable alternatives, all 4-bit quantized via MLX. Change it in **Settings → Language
Model**. Each downloads once while online and is reloaded automatically from cache on subsequent
launches (no need to re-tap Download). **Qwen3 4B** is a "thinking" model — its reasoning is shown
in a collapsible **Reasoning** section above each result and kept out of the saved output.

**Online models (optional).** When you have a cell signal, you can instead pick **Claude Sonnet
4.6** or **Claude Haiku 4.5** from the same picker. These stream from Anthropic's API rather than
running on-device, so there's nothing to download — instead the **Download** button becomes
**Authenticate** (or **Edit Authentication** once a key is saved). Tap it, paste an Anthropic API
key (from console.anthropic.com), and it's stored in the device Keychain and sent only to
Anthropic. Recording and transcription stay fully on-device; only the rewrite step of a cloud
model leaves the device, and only when one is selected — the offline models remain the default.
