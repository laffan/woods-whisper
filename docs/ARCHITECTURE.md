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
| `TextTransformService` | `GemmaTransformService`         | transcript + preset → text (LFM2.5/MLX) |
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
  document remember their own without a second store or a global setting. A `kind` of `.graph`
  makes the same container a **graph document** (below): the body lives in `nodes` instead of
  `paragraphs`, and everything around it — recordings, Auto transform, trash, `.wwdoc` sharing, the
  Markdown mirror — is untouched. Both keys decode as absent-friendly, so documents written before
  graphs existed load as `.document` with no nodes.
- **`GraphNode`** — one node of a graph document: its own `text`, a `parentID` (nil for a root), a
  `position` on the canvas, and optionally the `recordingID` of the clip it was spoken into. The
  text is the node's own copy — a transcript is *copied* in once, so editing, transforming, or
  re-recording a node never reaches back into the clip. Structure is that single parent pointer, so
  dragging a branch, re-parenting on a drop, the Markdown outline, and the canvas's "List Nodes"
  (`nodeEntries` — every node with its depth, in outline order) all walk the same thing;
  `Document.subtree(of:)` and `isAncestor(_:of:)` (both cycle-safe) are what a drop is checked
  against, since a cycle is a graph no outline could walk out of.
- **`GraphGroup`** — a ring drawn round a handful of nodes, with an optional label. Deliberately
  *not* structure: no parent, nothing hangs off it, and the outline walks straight past it — it's the
  mind-map equivalent of circling a cluster in pencil, which is why membership is a plain list of
  ids and a node can be in a group while hanging off a parent somewhere else. The ring's geometry
  isn't stored either; it's the union of the members' cards, so it follows them. Membership is
  edited by *moving nodes*: after a drag, the canvas re-measures each ring from the members that
  didn't move and adds or drops the ones that did, so a node can't hold itself in by its own
  presence.
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

**Where a capture's words land is carried by the clip, not by whoever recorded it.** A recording
made *into* a document — the record button, the Documents list's "+", an "insert here", a
"Revise" — is saved with a `Recording.bodyDestination` (`.append` / `.at(index)` /
`.replacing(paragraphID)`), and `AppModel.fillDocumentBody`, at the end of every transcription,
is the single place that files the text. That matters because the words may be a long way off: a
clip captured while the speech model is still downloading is left `.pending`, picked up by
`transcribePending` when the model becomes ready — this launch or a later one, since the
destination is persisted with the recording — and lands in the body then, with no one having to go
back and finish it by hand. The destination is cleared as soon as a transcription completes, so a
Retranscribe can't post the same paragraph twice. It's the same shape as `fillGraphNodes`, which
does the graph's half of the job, and for the same reason.

**Import text (iOS):** `AppModel.importText` — from the clipboard or a picked `.txt`/`.md` — joins
the same pipelines one step in, rather than getting a path of its own. Into a document it's split by
`Document.paragraphs(from:)` and appended to the body, so it lands exactly where a transcript would;
into the Inbox it becomes a `Recording.textEntry`, which is an ordinary Inbox row minus the audio.
Everything downstream — editing, transform, move-to-document, "Reset with Originals", the Markdown
backup — then works on it unchanged.

**Transform (iOS):** `AppModel.transformDocument` (whole body) / `transformParagraph` (one
paragraph) / `transformGraphNode` (one node) / `transformRecordingTranscript` (one clip's
transcript) → `TextTransformService.transform` → the result **replaces** the text in place rather
than appending a new block.

**Graph documents (iOS).** A graph is a `Document` with `kind == .graph`; `DocumentsView` routes to
`GraphDocumentView` (at the bottom of `DocumentDetailView.swift`, alongside the Inbox and the
recorder, so the app target picks it up without an xcodegen regen) on that flag alone, so every way
in (a row, the widget's deep link) agrees. The
canvas draws everything in *canvas coordinates* inside one big container and applies a single
transform — `scaleEffect(anchor: .topLeading)` then `offset` — so a canvas point `c` lands at
`c * scale + pan` and the inverse used by every gesture is one line. Five things are worth knowing:

- **A line meets a card's nearest edge**, and each end decides for itself, by measuring its four
  side midpoints against the other card's rectangle. The tempting test — which side the centre-to-
  centre ray exits through — is wrong for cards this shape: a node is three times wider than it is
  tall, so that ray leaves through the *top* as soon as the other node is about 18° above the
  horizontal, and a child sitting out to the right and a little high gets joined top-to-bottom.
- **A hold can run on into a chain.** While recording, a ring is drawn round the node being spoken
  into; leaving it files that clip, starts another, and hangs the new node off the last. The new
  node follows the finger until it *settles*, which needs a clock rather than the gesture — a finger
  held perfectly still sends no events, and stillness is exactly what's being waited for. On
  settling the position is committed once and the canvas centres on it. A clip too short to keep
  takes its node with it, so the next node checks its intended parent still exists before pointing
  at it: a dangling `parentID` would be a node in neither `rootNodes` nor anyone's `children`.
- **Nodes sit where they're put.** There is no simulation: a node's `position` is the truth, a drag
  moves it (and its branch), and nothing else ever does. An earlier build relaxed the graph with a
  force-directed layout, which read well right up until you tried to drop one node onto another and
  the target slid out of the way; it was removed in favour of this, and lives in the history if it's
  ever wanted back. Because positions are stable, the minimap is a real map — where a dot is, is
  where the node is.
- **A drag is one edit, measured in a space that isn't moving.** The live translation stays in view
  state and is written to the nodes only when the finger lifts, so dragging a branch doesn't rewrite
  the document (and its Markdown mirror) once per frame. Like pinning, positions don't bump
  `updatedAt` — where a node sits is layout, not an edit. The gesture reads `.global`, deliberately:
  a `DragGesture` measures against the coordinate space of the view it's attached to, and a node
  drag *moves that view*, so a local-space translation comes back halved and oscillating — the card
  flickers between the finger and half way there, and never lands on the node you were aiming at.
- **Arrangement happens only when asked**, and from one number. `DocumentStore.standardNodeGap` is
  the clear space this canvas leaves between two nodes; the child column, the push that makes room
  for an inserted node, and the air between sibling branches are all derived from it, so a tidied
  child, a new child and a dropped branch all land the same distance out.
  `DocumentStore.tidyChildren(of:in:)` is the one thing that moves nodes the user didn't drag:
  children into a column beside their parent, spaced by the *height of the branch hanging off each*
  so a child with a family doesn't land on its sibling.
  Inserting a node on an edge is the same idea in miniature — the branch below slides out by a
  node's width and the new node takes the middle of the widened gap, so it has the room the "+" had.
  Both go through one rigid `translate(subtreeOf:)`, which is why nothing below ever gets scrambled.
- **One press, read five ways.** A single `DragGesture(minimumDistance: 0)` decides between pan,
  selection box, hold-to-record, tap and double-tap, rather than stacking recognisers that would
  fight over the same touch. A *held* finger is always a recording — a root node under the finger,
  wherever it lands — which is the one gesture the canvas can't afford to make conditional, since
  it's the record button. Selecting is a **mode** instead (`isSelecting`, entered from ⋯ → Select
  Nodes), where a drag draws the box and a tap picks a card out; the "+" buttons stand down while
  it's on, so a stray fingertip can't add a node in the middle of choosing them. A tap that follows
  a tap is still recognised on the way **down** rather than on release, because it decides what
  letting go means (a node to type into, versus putting things away).
  The phase is anchored to the gesture's `startLocation`: a gesture the system
  cancels never sends `onEnded`, so rather than trusting leftover state, the next touch to begin
  somewhere else takes over. A touch that lands on a node never reaches the canvas at all, because
  SwiftUI gives a child's gesture priority over its ancestors'.
- **Pan and zoom compose.** Both gestures move `pan` *incrementally* — neither re-derives it from
  where it started — so the drag that keeps running through a pinch can pan while the pinch zooms,
  instead of one overwriting the other on every frame. The pinch also settles the ambiguity of the
  touch it shares: a second finger means this was never a hold. Releasing a pan hands its velocity
  to a glide that steps `pan` down to a stop by hand rather than through `withAnimation`: an
  animation would set the state to its destination at once and leave the next touch to start from
  there, so grabbing the coasting canvas would jump it. Any finger down cancels the glide.

**Lining a selection up.** `GraphArrange` (in the kit) does the arithmetic behind Align Left, Align
Top and the two Distributes, over `GraphNodeBox` values the view builds from its *measured* card
sizes — alignment is about edges, and a node's stored position is its centre, so the store can't
answer it alone. Distributing evens the gaps between cards rather than the distance between centres,
which is the difference between a tidy column and a tall card crowding its neighbours. The result is
a `[UUID: GraphPoint]` written back through the same `moveNodes` a drag ends with: one edit, no
`updatedAt` bump, and only the nodes that actually move are in it.

**Graph capture (iOS).** Holding the canvas makes the node *first* (there has to be something on
screen recording into) and files the clip on release via `AppModel.captureGraphNode`, which points
the node at the recording before adding it. The Documents list's row "+" is the same hold on a row
that has no canvas: it starts the recorder on hold and, on release, appends the clip to an ordinary
document's body (`addDeviceRecording(body: .append)`) or gives a graph a fresh root node
(`DocumentStore.addRootNode`, placed below everything already drawn) to record into. The node is
made on release rather than on the hold there, because nothing on the list would show it. Everything after that is the ordinary transcription
path: `transcribe` runs, the document's Auto transform has its say, and only then does
`fillGraphNodes` copy the words into any node that's still empty and pointed at that clip. Hanging
it off `transcribe` is what makes it work for arrivals that know nothing about graphs —
`DocumentStore.addRecording` gives a Watch clip, a shared audio file, or a recording moved in from
the Inbox a node of its own (unless one already claims it), and the words catch up through the same
hook. Filling only *empty* nodes is what keeps a Retranscribe from overwriting what you've since
typed; "Revise" empties the node deliberately, which is exactly how it replaces it.

Microphone permission is *checked* (`AVAudioApplication.shared.recordPermission`), never awaited, on
every path that starts capture from a hold — the canvas's, both "+" buttons' and the Documents
list's. By the time a hold
is recognised the user is already holding, so an `await` there is a beat of silence at the head of
every clip and a promise that has to come back before anything happens at all. Asking is a separate
path, taken once, the first time a hold finds permission undetermined.

**Auto transform (iOS):** `AppModel.transcribe` notes whether the recording's `transcript` was nil
*before* it ran — the test for "first transcription" — and on success calls `applyAutoTransform`,
which looks up the document's `autoTransformPresetID` — or, for a **graph**, the app-wide
`AppSettings.graphAutoTransformPresetID`, since a graph has no bottom bar to hang a per-document
toggle from — and runs it through the same
`transformRecordingTranscript` path. Hanging it off `transcribe` (rather than off each capture site)
is what makes it apply to every arrival — Watch clip, device capture, shared audio — with no branch
of its own; anchoring it to the first transcription is what keeps **Retranscribe** and **Reset**
returning the original words. `fillDocumentBody` and `fillGraphNodes` both run *after* the
transform, so what lands in a paragraph or a node is the shaped text rather than a flash of the raw
transcription.

**Transcription text size (iOS).** How big transcription text is set — a document's paragraphs, an
Inbox entry, a graph node — is one number, chosen in Settings → Display and stored in
`AppSettings.transcriptTextSize`. The app root reads it with `@AppStorage` and hands it down the
whole hierarchy as the `transcriptTextSize` environment value, so changing it invalidates every view
that draws such text rather than taking effect on whatever redraws next. `InlineTextStyle` turns that
number into both halves of a style — the SwiftUI `Font` a row is drawn with and the `UIFont` the
in-place `UITextView` editor uses — which is what keeps text from resizing the instant you tap it.
The compact blocks (an Inbox transcript, a node card) sit two points under the chosen size, the step
they've always been below body text.

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
  documents reads the same wherever it lands. A **graph** needs no branch of its own here: it's
  `Document.combinedText` that differs, handing over `Document.outline` — the nodes as an indented
  bullet list — so the mirror, Copy, Share and a whole-document transform all get the graph in the
  shape it already has. (A node with nothing in it yet isn't given a bullet, and whatever hangs off
  it moves up a level, so the outline never has an empty line with children dangling under it.)
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
