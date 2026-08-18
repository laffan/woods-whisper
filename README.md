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
├── Apps/iOSWidgets/                 # iOS widget extension (Recent Documents widget,
│                                    #   New Recording Lock Screen widget + Control,
│                                    #   recording Lock Screen / Dynamic Island controls)
├── Apps/Watch/                      # watchOS app (record button + recordings list)
├── Apps/WatchComplication/          # watch-face "New Recording" complication
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

   The iPhone/iPad advertises itself — and shows up on the Watch — under the name in
   **Settings → About → Device name**. It starts as the device's own name (clear the field to go
   back to it) and you can type anything you like; an already-paired Watch keeps the old name until
   you pair it again.

   The standard **Watch → iPhone** path uses WatchConnectivity and needs no configuration.

## Capturing and organizing

- **Inbox is its own tab.** Watch clips and one-tap "New Recording" captures land in the **Inbox**,
  now the first top-level section (ahead of Documents) rather than a row inside the documents list.
  It reads as a capture feed — **newest first**, each entry showing its transcript preview over the
  capture date and time. There's no play control on the rows; the text runs the full width.
- **Inbox gestures.** **Tap** an entry to edit its transcript — **in place**, where it sits (see
  *Editing in place* below). **Swipe left** for **Move** (into a document) and **Delete**; **swipe
  right** for **Copy** and **Transform**. Long-press still enters batch selection.
- **Editing in place.** Editing never opens a sheet over what you're reading. Tap an Inbox entry (or
  double-tap a paragraph in a document, or swipe it right → **Edit**) and *that block* becomes the
  editor: an outlined box that grows with the text, in the type it was already set in, everything
  around it left where it was. The actions sit along the bottom of that same box, inside the
  outline — a compressed row of icons at the **left**, **Done** at the **right**. For an Inbox entry
  the icons are **Copy / Share / Transform / Reset** (Share hands off either the text or the audio
  clip); for a paragraph they're **Revise / Insert / Transform**. **Done** saves and closes; blank
  lines you added split the block into separate paragraphs.
- **One red record button.** Recording isn't a toolbar glyph any more. In the **Inbox** and inside a
  **document** it's a plain red dot, centered above the bottom bar — nothing behind it, the text
  scrolling past underneath — and it does what the mic did there before: a clip filed into the
  Inbox, or one added to the document (its transcript appended to the body).
- **Auto transform.** A toggle at the bottom of the Inbox and of every document (a **graph** has no
  bottom bar, so its equivalent — **Auto transform nodes** — lives in **Settings → Graphs** and
  applies to every graph). Flip it on and a
  list of your transforms opens; pick one and it runs by itself on every new recording the moment
  that recording is first transcribed — so captures arrive already cleaned up, summarized, or
  whatever else you asked for. The bar then carries the transform's name (tap it to pick another,
  flip the toggle off to stop). Each document remembers its own choice, and so does the Inbox. Only
  a *first* transcription is transformed: **Retranscribe** and **Reset** still give you the original
  words back.
- **Graph documents (experimental).** The **✎** button now asks what you're making: a **Document** or
  a **Graph**. A graph is a mind map on a pannable, zoomable canvas over a very light grid — endless
  in every direction, so there's always more room a drag away. **Hold anywhere on the canvas** and a
  node appears under your finger and starts recording; lift and it stops, transcribes, and the words
  drop into that node — one gesture for "make a node and say what's in it". It's the same every
  time, wherever you hold: a new root node, right there. **Double-tap** instead and you get a node
  to type into.
- **Speak a whole chain without lifting your finger.** While a hold is recording, a thin ring is
  drawn around the node you're speaking into. Slide out of the ring and that clip is filed there and
  then, a fresh one starts, and the node it makes hangs off the one you just finished — so a train
  of thought becomes a line of linked nodes in one continuous gesture. The new node follows your
  finger until it settles (a second in one place is enough), then the canvas slides over to centre
  it, leaving room to strike out in any direction for the next one.
- **Working with nodes.** Nodes are the same edit blocks as everywhere else, shrunk to
  cards: **tap twice** to edit one in place, **long-press** for the actions a paragraph gets from a
  swipe (Edit, Add Child, Revise, Transform, Delete) as a dropdown. **Drag** a node and its children
  come with it; **drop it on another node** and the whole branch hangs off that one — settling into
  place beside its new parent, below the children already there and clear of anything else. Nodes stay
  exactly where you put them — nothing rearranges them behind your back, though **Tidy Children**
  (in a node's edit bar, and in its long-press menu) will line a node's children up beside it on
  request, each with its own branch in tow. The **"+"** tucked inside a node's right edge adds a child and the
  one midway along a line drops a node between the two it joins — evenly, with the same room either
  side, pushing the branch below out of the way; **tap** either to type, or **hold** either to
  record into the new node the way the canvas does. Whenever a hold is recording, the elapsed
  counter floats above your finger, clear of the node it's filling. Pinch to zoom, drag while
  pinching to move around at the same time, and let go mid-drag for the canvas to coast to a stop.
  There's no bottom bar at all — the hold is the record button, and a graph's auto transform is an
  app-wide setting (**Settings → Graphs**) rather than a per-document toggle — so the canvas runs
  all the way to the edge.
- **Picking several nodes out.** The hold belongs to recording, so selecting is asked for: **⋯ →
  Select Nodes**. In that mode a drag on the canvas draws a selection box — everything it touches is
  selected — and a tap on a card takes it in or out. Any one of the selected nodes drags the whole
  lot, and a bar along the bottom carries what you can do with them; **Done** leaves the mode.
- **Lining a selection up.** That bar's second row has **Align Left**, **Align Top**, **Distribute
  Horizontal** and **Distribute Vertical**. Aligning puts every selected card's left (or top) edge
  on the leftmost (or topmost) one; distributing holds the two on the ends where they are and evens
  out the gaps between the rest — gaps between the *cards*, so a tall one doesn't crowd its
  neighbours. Only the selected nodes move; their children stay where they are. Distributing needs
  three cards to mean anything, so with two it's greyed.
- **Groups.** Select a few nodes and tap **Group**: a dashed ring is drawn round them, and it
  follows them wherever they go. Tap the corner to name it (or to ungroup), drag the ring's **edge**
  to move everything inside, and drag a node **in or out** of the ring to change what's in the
  group — membership is a matter of where things are, not a list to manage. A ring left with fewer
  than two nodes dissolves itself.
- **Unlink.** A node's edit bar (and its long-press menu) has an **unlink** action: it takes the
  node out of the tree without taking its words with it — its parent and its children are joined to
  each other, so the branch survives, and the node floats free where it stands.
- **Finding your way around a graph.** A **minimap** sits along the bottom: every node as a dot
  inside a box showing what's on screen — touch or drag it to go there. The **⋯** menu adds **List
  Nodes** (the graph as an indented list, in outline order; tap a line to fly to that node),
  **Center Graph**, and a switch for the minimap itself. The same menu's **Copy Outline** / **Share
  Outline** — and the backup folder — hand over the graph as a **Markdown outline**: one bullet per
  node, indented by depth, in the order the canvas reads.
- **Record straight to a document from the Watch.** The iPhone syncs your document list to the Watch
  over WatchConnectivity; swipe left on the Watch's record screen to pick a target document (or the
  Inbox). The chosen target's name shows on the record screen, and clips captured there are filed into
  that document on the iPhone/iPad instead of the Inbox. (Targets sync over the paired-iPhone path; the
  direct-to-iPad transports still file into the Inbox.)
- **Record into a document from the list.** Every row in **Documents** carries a **"+"** just left
  of its open arrow — the graph canvas's button, on a list row. **Hold** it and recording starts
  where you are; let go and it stops, transcribes itself, and lands in that document: one more
  paragraph at the end of an ordinary document, or a new root node in a graph. The row shows the
  counter while you hold. (**Tap** it rather than holding and it simply opens the document.)
- **Pin documents.** Swipe a document and tap **Pin** to hold it at the top of the list.
- **Bulk actions on documents.** **Long-press** a document to enter selection mode, then tap the
  others you want (or **Select All**). The bar along the bottom applies **Delete**, **Copy**,
  **Pin** — **Unpin** once everything selected is pinned — and **Share** to the whole selection.
  Copy and Share hand over a single Markdown file with each document under its own heading, the
  same way the backup folder writes them. **Done** leaves selection mode.
- **Insert while editing.** While editing a paragraph, **Insert** records a clip, transcribes it, and
  splices the text in at the cursor — the clip is saved with the document's other recordings.
- **Find & replace.** The whole-document editor has a find/replace bar at the bottom (the magnifying
  glass in the editor's toolbar) — search, step through matches, and Replace / Replace All.
- **Share a whole document as a file.** From a document's overflow menu, **Share as Woods Whisper
  File** exports a single `.wwdoc` file bundling the audio *and* the current edited transcriptions.
  Send it to another device (AirDrop, Files, Messages…) and open it there to rebuild the document —
  no network round-trip. Woods Whisper registers `.wwdoc` so it can both create and receive them.
- **Share audio in.** Send an audio file to Woods Whisper from the iOS share sheet / "Open in…"; it's
  imported into the Inbox and transcribed like any other recording.
- **Import text you already have.** Not everything starts as speech. The **⋯** menu — top right of a
  document, and top right of the Inbox — offers **Import from Clipboard** and **Import Text
  File…** (`.txt`, `.md`). Into a **document**, the text is split on blank lines and appended to the
  body as ordinary paragraphs, editable and transformable like any other. Into the **Inbox** it
  becomes an entry of its own — no audio behind it, already "transcribed", so you can edit it,
  transform it, or move it into a document exactly like a captured clip. (Entries that arrived as
  text quietly drop the actions that need audio: no play control, no Retranscribe, no Reset.)
- **Number Paragraphs.** A built-in transform that numbers the paragraphs (applied locally, so it needs
  no language model).
- **Local backup folder.** Pick a folder in **Settings → Local Backup** and Woods Whisper keeps a
  plain-Markdown copy of everything you write there — see below.
- **Recording controls on the Lock Screen.** Start a recording and it follows you out of the app: a
  Live Activity appears on the Lock Screen (and in the Dynamic Island) for as long as capture runs,
  carrying every control the in-app recorder has — **Pause / Continue**, **Save**, and **Discard** —
  plus the elapsed counter, which ticks itself and skips the paused stretches the same way. So you
  can start a clip, pocket the phone, and still run it to its end without unlocking. It goes away
  the moment the recording does. (Discard there doesn't ask twice — a locked screen is nowhere to
  put a confirmation — so it's the quietest of the three buttons. The live gain meter is the one
  thing left in the app: it moves ten times a second, which the system rate-limits away.)
- **Recent Documents widget.** A Home Screen widget (small / medium / large) with a **New
  Recording** button across the top and, below it, your most recently updated documents — pinned
  first, the same order as the Documents list. **Tap any row to open that document straight away**,
  in every size. How many rows fit is measured against the widget's actual height, so a bigger
  phone shows more. It updates whenever a document changes and works fully offline.

## Local backup folder

Choose a folder in **Settings → Local Backup** (anywhere the Files app can reach: On My iPhone/iPad,
iCloud Drive, an external drive) and Woods Whisper creates a **`WoodsWhisper`** folder inside it:

```
<your folder>/WoodsWhisper/
├── Inbox/
│   ├── 2026-07-31 09-14-02.md      # one file per Inbox recording, named by capture time
│   └── 2026-07-31 14-30-05.md
└── Documents/
    ├── Field Notes.md              # one file per document, named by its title
    ├── Route Plan.md               # a graph is written as a Markdown outline
    └── Trip Log.md
```

Every creation and edit saves a fresh copy of the current state — the newest version **overwrites**
the previous one (no history is kept, for now). Writes are coalesced while you type and only files
whose text actually changed are rewritten. **Text only:** audio stays in the app, so the folder is
readable in any Markdown editor (a **graph** is written as its outline — nested bullets — which is
also what its Copy and Share hand over). Turning backup off leaves the files where they are.

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

> **New source files need a fresh `xcodegen generate`.** The spec globs `Apps/iOS` when the project
> is generated, so a file added to an app target since your last run won't be in an existing
> `.xcodeproj` until you generate again — which is why several features (the recorder, the Inbox,
> the graph canvas) ride along in an existing file rather than one of their own. Files added under
> `Packages/WoodsWhisperKit` are picked up by SwiftPM on their own.

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
> **iOS widgets (built in).** A WidgetKit extension (`Apps/iOSWidgets`, target
> `WoodsWhisperWidgets`) ships the **Recent Documents** Home Screen widget, the **New Recording**
> Lock Screen widget and iOS 18 Control, and the **recording Live Activity** — the Lock Screen /
> Dynamic Island recorder described above (it needs `NSSupportsLiveActivities` in the app's
> Info.plist, which is already there). It's embedded in the iOS app, so it builds
> with the default scheme — give it a signing team alongside the other targets. The app and the
> extension share the App Group `group.com.woodswhisper.app` (declared in `project.yml`; xcodegen
> writes the entitlements files): the app mirrors a small snapshot of the most recent documents
> into it, which is all the widget reads — document text and audio never leave the app's own
> container. On a free Apple ID the extra app-extension App ID and App Group can be painful to
> provision; if that blocks you, delete the `WoodsWhisperWidgets` target and the two `entitlements`
> blocks from `project.yml` and everything else still builds ("New Recording" stays available via
> App Intents, which need no extra target).

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
