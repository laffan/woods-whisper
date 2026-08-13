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
  Carries `origin` (watch/phone/pad). `Codable`, so it travels between devices as-is. An Inbox entry
  made by *importing text* is the same type with no audio behind it (`Recording.textEntry`, empty
  `audioFileName`, already `.done`): `isTextOnly` is the single flag every audio-shaped path checks,
  so one kind of row covers both and nothing downstream needs a second model. `DocumentStore` hands
  such an entry an `audioURL` that deliberately can't exist, rather than one that resolves to the
  audio *directory* — so `fileExists` answers "no", not "yes, it's a folder".
- **`Document`** — a coherent body of ordered, editable **`Paragraph`**s, plus the source
  **`Recording`**s it was built from (kept in a separate "Recordings" section). iOS/iPadOS only.
  Re-transcribing a recording appends its transcript as a paragraph; transforming rewrites the
  paragraphs in place. The **Inbox** is a `Document` rendered as a flat recordings list. It also
  carries `autoTransformPresetID` — the "Auto transform" choice — which is why the Inbox and each
  document remember their own without a second store or a global setting.
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

**Import text (iOS):** `AppModel.importText` — from the clipboard or a picked `.txt`/`.md` — joins
the same pipelines one step in, rather than getting a path of its own. Into a document it's split by
`Document.paragraphs(from:)` and appended to the body, so it lands exactly where a transcript would;
into the Inbox it becomes a `Recording.textEntry`, which is an ordinary Inbox row minus the audio.
Everything downstream — editing, transform, move-to-document, "Reset with Originals", the Markdown
backup — then works on it unchanged.

**Transform (iOS):** `AppModel.transformDocument` (whole body) / `transformParagraph` (one
paragraph) / `transformRecordingTranscript` (one clip's transcript) → `TextTransformService.transform`
→ the result **replaces** the text in place rather than appending a new block.

**Auto transform (iOS):** `AppModel.transcribe` notes whether the recording's `transcript` was nil
*before* it ran — the test for "first transcription" — and on success calls `applyAutoTransform`,
which looks up the document's `autoTransformPresetID` and runs it through the same
`transformRecordingTranscript` path. Hanging it off `transcribe` (rather than off each capture site)
is what makes it apply to every arrival — Watch clip, device capture, shared audio — with no branch
of its own; anchoring it to the first transcription is what keeps **Retranscribe** and **Reset**
returning the original words. In a document the body text is read back *after* `transcribe` returns,
so the transformed text is what lands in the body.

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

The widget reserves its top slot for a **New Recording** button (`StartRecordingIntent` /
`woodswhisper://record`, the same action as the Lock Screen widget and the Control) and fills the
rest with document rows, as many as `GeometryReader` measures room for — widget heights vary by
device, so the count isn't hardcoded per family.

**Recording Live Activity.** While a recording runs, the app raises a Live Activity so the recorder
is reachable from the Lock Screen and the Dynamic Island. Three pieces, in the shared kit so the app
and the widget extension agree on all of it:

- `RecordingActivityAttributes` — what's on screen. The elapsed counter is *not* pushed: the content
  state carries a **virtual** `startedAt` ("now minus the time recorded so far", reset on each
  continue) and the widget renders it with SwiftUI's self-ticking timer text. So the app only sends
  an update when the state genuinely changes — pause, continue, stop — instead of once a second, and
  the counter still skips paused stretches the way the in-app one does. The gain meter is left out
  on purpose: at ten changes a second it's exactly what the system's update rate limit exists for.
- `RecordingActivityController` — start / update / end, and the one place that knows a run killed
  mid-recording can leave a stale activity behind (it clears any before adding one).
- `RecordingRemote` + the four `LiveActivityIntent`s (pause / resume / save / discard) — the way a
  press gets back to the recorder. `RecordingSheet` owns the `AudioRecorder`, so while it's
  capturing it *registers a handler* with `RecordingRemote` and each intent calls straight through
  to it. `LiveActivityIntent` is the flavour the system performs in the **app's own process**, and
  the `audio` background mode keeps that process alive for the recording itself, so the press lands
  on the live recorder rather than on a copy of its state. The handler is called directly rather
  than published for a view to observe: this arrives while the app is backgrounded behind a locked
  screen, which is no time to depend on SwiftUI getting around to a view update. The handler is
  released on every exit path, so a press against an activity the system hasn't cleared yet does
  nothing.

Tapping anything routes by two mechanisms, picked by family in `tapTarget`: the medium and large
families link out by URL (`woodswhisper://document/<uuid>` for a row), while `systemSmall` — which
WidgetKit gives a single `Link` target for the whole widget — runs an App Intent instead, the one
way to give it several tap targets. A row's `OpenDocumentIntent` sets `openAppWhenRun`, so it
performs in the app's own process and reaches `DocumentLauncher`. `ContentView` watches that
launcher (rather than `onOpenURL` alone) so both routes switch to the Documents tab, and
`DocumentsView` consumes the id and pushes the document.
