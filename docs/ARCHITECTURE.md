# Architecture

## Layers

```
┌──────────────────────────────────────┐   ┌──────────────────────────┐
│  Apps/iOS  (iPhone + iPad)            │   │  Apps/Watch  (watchOS)   │
│  • Recordings / Documents             │   │  • Record button         │
│  • Settings + pairing                 │   │  • Recordings list       │
│  • Apps/iOS/Services/ (ML impls):     │   │  • Sends to paired device│
│      Parakeet (ASR) · Gemma 3 (LLM)   │   │                          │
│      + FluidAudio / MLX packages      │   │                          │
└──────────────────┬───────────────────┘   └────────────┬─────────────┘
                   │  depends on                          │  depends on
                   ▼                                      ▼
        ┌───────────────────────────────────────────────┐
        │       WoodsWhisperKit  (SPM, no external deps) │
        │  Models · Audio · Storage · Connectivity       │
        │  Service *protocols* · Utilities               │
        └───────────────────────────────────────────────┘
```

**Why the ML SDKs live in the iOS app target, not the shared package:** FluidAudio and MLX
don't support watchOS. SPM resolves a package's *entire* dependency graph for every platform a
consumer targets, so if the shared package (which supports watchOS) depended on them — even
conditionally — watchOS resolution would fail. Instead the shared package is dependency-free and
defines only the protocols (`TranscriptionService`, `TextTransformService`); the concrete
implementations and the FluidAudio/MLX packages are attached to the iOS app target in
`project.yml`. The implementations still guard SDK calls with `#if canImport(...)`.

## Key abstractions

| Protocol               | iOS implementation              | Purpose                                |
|------------------------|---------------------------------|----------------------------------------|
| `TranscriptionService` | `ParakeetTranscriptionService`  | audio file → text (Parakeet/CoreML)    |
| `TextTransformService` | `GemmaTransformService`         | transcript + preset → text (Gemma/MLX) |
| `RecordingSender`      | `PhoneSessionTransport`, `LocalNetworkClient`, `BluetoothRecordingClient` | send a recording to a host |
| `RecordingReceiver`    | `PhoneSessionTransport`, `LocalNetworkServer`, `BluetoothRecordingServer` | receive recordings on a host |

Depending on protocols (not the SDKs) keeps the UI testable and lets the Watch reuse the audio,
storage, and connectivity code without the model dependencies.

## Data model

- **`Recording`** — metadata for one audio clip (audio bytes live on disk via `RecordingStore`).
  Carries `origin` (watch/phone/pad). `Codable`, so it travels between devices as-is.
- **`Document`** — a transcript plus an ordered list of **`Transformation`**s (one per preset
  run). iOS/iPadOS only.
- **`PromptPreset`** — a named, reusable instruction (`systemPrompt` + `template` with a
  `{{transcript}}` token) plus generation params. Five built-ins ship; users add their own.
- **`DeviceLink`** — describes the Watch↔host pairing; for the direct-to-iPad path it stores the
  iPad's `host`/`port`/`pairingSecret`.

## Pipelines

**Capture (Watch or iOS):** `AudioRecorder` → 16 kHz mono `.m4a` → `RecordingStore`.

**Watch → host:** `WatchModel.send` picks a `RecordingSender` based on `WatchSettings.transport`
(paired iPhone via WCSession, or direct to iPad via local network) and ships
`RecordingTransfer` + audio bytes. The host's receiver calls `RecordingStore.ingest`.

**Transcribe (iOS):** `AppModel.transcribeToDocument` → `TranscriptionService.transcribe`
(decodes to 16 kHz `[Float]`, runs Parakeet) → new `Document`.

**Transform (iOS):** `AppModel.runTransformation` → `TextTransformService.transform` streams
Gemma output token-by-token into a new `Transformation` appended to the document.

## Persistence

Deliberately dependency-free: JSON index files + audio payloads in Application Support
(`RecordingStore`, `DocumentStore`). Easy to reason about and identical across platforms. Swap
for SwiftData later if desired — only the two stores would change.
