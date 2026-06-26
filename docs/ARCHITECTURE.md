# Architecture

## Layers

```
┌──────────────────────────────────────┐   ┌──────────────────────────┐
│  Apps/iOS  (iPhone + iPad)            │   │  Apps/Watch  (watchOS)   │
│  • Recordings / Documents             │   │  • Record button         │
│  • Settings + pairing                 │   │  • Recordings list       │
│  • Apps/iOS/Services/ (ML impls):     │   │  • Sends to paired device│
│      Parakeet (ASR) · MLX LLM         │   │                          │
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
implementations and the FluidAudio/WhisperKit/MLX packages are attached to the iOS app target in
`project.yml`. The implementations still guard SDK calls with `#if canImport(...)`.

## Key abstractions

| Protocol               | iOS implementation              | Purpose                                |
|------------------------|---------------------------------|----------------------------------------|
| `TranscriptionService` | `SpeechTranscriptionCoordinator` → `ParakeetTranscriptionService` (FluidAudio) / `WhisperTranscriptionService` (WhisperKit) | audio file → text; coordinator routes to the engine for the selected `SpeechModel` |
| `TextTransformService` | `GemmaTransformService`         | transcript + preset → text (Gemma/MLX) |
| `RecordingSender`      | `PhoneSessionTransport`, `LocalNetworkClient`, `BluetoothRecordingClient` | send a recording to a host |
| `RecordingReceiver`    | `PhoneSessionTransport`, `LocalNetworkServer`, `BluetoothRecordingServer` | receive recordings on a host |

Depending on protocols (not the SDKs) keeps the UI testable and lets the Watch reuse the audio,
storage, and connectivity code without the model dependencies.

## Data model

- **`Recording`** — metadata for one audio clip (audio bytes live on disk via `RecordingStore`).
  Carries `origin` (watch/phone/pad). `Codable`, so it travels between devices as-is.
- **`Document`** — a coherent body of ordered, editable **`Paragraph`**s, plus the source
  **`Recording`**s it was built from (kept in a separate "Recordings" section). iOS/iPadOS only.
  Re-transcribing a recording appends its transcript as a paragraph; transforming rewrites the
  paragraphs in place. The **Inbox** is a `Document` rendered as a flat recordings list.
- **`PromptPreset`** — a named, reusable instruction (`systemPrompt` + `template` with a
  `{{transcript}}` token) plus generation params. Three built-ins ship; users add their own.
- **`DeviceLink`** — describes the Watch↔host pairing; for the direct-to-iPad path it stores the
  iPad's `host`/`port`/`pairingSecret`.

## Pipelines

**Capture (Watch or iOS):** `AudioRecorder` → 16 kHz mono `.m4a` → `RecordingStore`.

**Watch → host:** `WatchModel.send` picks a `RecordingSender` based on `WatchSettings.transport`
(paired iPhone via WCSession, or direct to iPad via local network) and ships
`RecordingTransfer` + audio bytes. The host's receiver calls `RecordingStore.ingest`.

**Transcribe (iOS):** `AppModel.transcribe` → `TranscriptionService.transcribe`
(`SpeechTranscriptionCoordinator` routes to Parakeet — decoding to 16 kHz `[Float]` — or to
WhisperKit by file path) → sets the recording's `transcript`. "Re-transcribe" then appends that
text to the document body as a paragraph.

**Transform (iOS):** `AppModel.transformDocument` (whole body) / `transformParagraph` (one
paragraph) → `TextTransformService.transform` → the result **replaces** the paragraphs in place
rather than appending a new block.

## Persistence

Deliberately dependency-free: JSON index files + audio payloads in Application Support
(`RecordingStore`, `DocumentStore`). Easy to reason about and identical across platforms. Swap
for SwiftData later if desired — only the two stores would change.
