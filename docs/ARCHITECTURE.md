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

**Local backup mirror (optional).** When the user picks a folder in Settings, `LocalBackupStore`
keeps a plain-Markdown copy of the *text* there — a `WoodsWhisper` folder containing `Inbox/`
(one file per Inbox recording, named by capture timestamp) and `Documents/` (one file per
document, named by its title). Two pieces:

- `MarkdownBackup` — pure: documents in, `[relative path: file contents]` out. All the naming and
  formatting rules (and their tests) live here, no disk access. Its per-document rendering is also
  what the Documents list's batch Copy/Share hand over (`MarkdownBackup.combined`), so a bundle of
  documents reads the same wherever it lands.
- `LocalBackupStore` — the stateful half: holds the chosen folder as a security-scoped bookmark
  (the folder is outside the sandbox), coalesces change notifications, and does the file work off
  the main actor.

`DocumentStore.persistDocuments()` is the single choke point every mutation already runs through,
so it's the only hook needed: each save schedules a sync. Only files whose contents changed are
rewritten, and a manifest of what the previous sync wrote is kept so a renamed or deleted document
can be pruned without ever touching a file the app didn't write. The newest version overwrites the
previous one — no history, and no audio.

**Widget snapshot.** The iOS "Recent Documents" Home Screen widget (`Apps/iOSWidgets`) runs in its
own process and can't read Application Support, so `WidgetSnapshotStore` mirrors a small JSON list
of the top documents — id, title, `updatedAt`, pinned flag, one-line preview — into the shared App
Group container (`group.com.woodswhisper.app`) and asks WidgetKit to reload the timeline. It hooks
the same `persistDocuments()` choke point (plus one seed write at load), skips the write when the
visible rows haven't changed, and degrades to a no-op if the App Group isn't provisioned.

Tapping a row opens that document by two routes that meet at `DocumentLauncher`: the medium and
large families link out to `woodswhisper://document/<uuid>`, while `systemSmall` — which WidgetKit
gives a single tap target, ignoring per-row `Link`s — uses an `OpenDocumentIntent` whose
`openAppWhenRun` performs it in the app's own process. `ContentView` watches the launcher (rather
than `onOpenURL` alone) so both routes switch to the Documents tab, and `DocumentsView` consumes
the id and pushes the document.
