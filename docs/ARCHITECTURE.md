# Architecture

## Layers

```
┌─────────────────────────────┐   ┌──────────────────────────┐
│  Apps/iOS  (iPhone + iPad)  │   │  Apps/Watch  (watchOS)   │
│  • Recordings / Documents   │   │  • Record button         │
│  • Model interaction (LLM)  │   │  • Recordings list       │
│  • Settings + pairing       │   │  • Sends to paired device│
└──────────────┬──────────────┘   └────────────┬─────────────┘
               │  depends on                    │  depends on
               ▼                                ▼
        ┌───────────────────────────────────────────────┐
        │           WoodsWhisperKit  (SPM)               │
        │  Models · Audio · Storage · Transcription      │
        │  Transform · Connectivity · Utilities          │
        └───────────────────────────────────────────────┘
                 │                         │
        #if canImport(FluidAudio)   #if canImport(MLXLLM)
                 ▼                         ▼
            Parakeet (ASR)            Gemma 3 (LLM)
            iOS/iPadOS only           iOS/iPadOS only
```

The shared package compiles on **both** platforms. The heavy ML SDKs are linked **only into the
iOS app target** (see `Package.swift` platform conditions) and are gated behind
`#if canImport(...)`. On watchOS those code paths throw `.unsupportedPlatform`, so the Watch
binary stays small and never tries to load a model.

## Key abstractions

| Protocol               | iOS implementation              | Purpose                                |
|------------------------|---------------------------------|----------------------------------------|
| `TranscriptionService` | `ParakeetTranscriptionService`  | audio file → text (Parakeet/CoreML)    |
| `TextTransformService` | `GemmaTransformService`         | transcript + preset → text (Gemma/MLX) |
| `RecordingSender`      | `PhoneSessionTransport`, `LocalNetworkClient` | send a recording to a host |
| `RecordingReceiver`    | `PhoneSessionTransport`, `LocalNetworkServer` | receive recordings on a host |

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
