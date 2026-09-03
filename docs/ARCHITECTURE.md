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
  `position` on the canvas, an optional `colorID` (see `GraphPalette`), and optionally the
  `recordingID` of the clip it was spoken into. The
  text is the node's own copy — a transcript is *copied* in once, so editing, transforming, or
  re-recording a node never reaches back into the clip. Structure is that single parent pointer, so
  dragging a branch, re-parenting on a drop, the Markdown outline, and the canvas's "List Nodes"
  (`nodeEntries` — every node with its depth, in outline order) all walk the same thing;
  `Document.subtree(of:)` and `isAncestor(_:of:)` (both cycle-safe) are what a drop is checked
  against, since a cycle is a graph no outline could walk out of.
- **`GraphStyle`** — the two things about a node that are *drawing* rather than content, kept where
  they can be tested. **`GraphPalette`** names the inks a node or a ring can be given — the same six
  ids an Inbox tag uses, since the app should have one vocabulary of colour — and the app maps a name
  to a light/dark pair in `WW.paletteColor(_:)`, this package drawing nothing itself. **`GraphHeading`**
  parses the `#` / `##` a node's text may open with: the level (one is bigger than two), the text
  with the marker taken off, and how many points bigger it's set. The marker stays in the stored
  text — so editing shows it again, and the exported outline keeps a Markdown heading as a Markdown
  heading — while `GraphNode.displayText` is what the canvas and the node list draw. Three hashes or
  more isn't a size the canvas has, so it stays plain text rather than losing a marker to nothing.
- **`GraphGroup`** — a ring drawn round a handful of nodes, with an optional label and `colorID`.
  Deliberately *not* structure: no parent, nothing hangs off it, and the outline walks past it — it's the
  mind-map equivalent of circling a cluster in pencil, which is why membership is a plain list of
  ids and a node can be in a group while hanging off a parent somewhere else. The ring's geometry
  isn't stored either; it's the union of the members' cards, so it follows them. Membership is
  edited by *moving nodes*, and only ever in one direction: after a drag, the canvas re-measures each
  ring from the members that didn't move (so a node can't hold itself in by its own presence) and
  **adds** the ones that came to rest inside it. Nothing an ordinary drag does removes a node from a
  ring — a branch travelling with its parent, or a card re-settled by a drop, keeps every group it
  belongs to. Leaving is asked for: a **⌘ drag** clear of the ring, the same gesture that takes a
  card out of the tree (`updateGroupMembership(after:in:leaving:)`).
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
text to the document body.

**Two paragraph rules, by who wrote the text.** Text the app *produced* — a transcript, a
transform's answer — is split by `Document.paragraphs(fromLinesOf:)`, one paragraph per line: a
transform can hand back a list or a set of points separated by a single newline, and filing that as
one paragraph leaves text that *reads* as several sections but is one, with no inter-paragraph "+"
between them and nothing to reorder, swipe or transform on its own. Text *you* wrote — an in-place
edit, an imported file, the clipboard — keeps `Document.paragraphs(from:)`, blank lines only, so a
soft break you typed stays inside its paragraph.

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
than appending a new block — split back into paragraphs by the line rule above wherever it lands in
a document body.

**A model's reasoning never becomes your words.** The two filters a streamed response passes through
— `StopSequenceFilter` (drops the turn-end marker and everything after it) and `ThinkSplitter`
(separates a `<think>…</think>` block from the answer) — live in the kit, in `StreamFilters.swift`,
precisely because that's the guarantee a reasoning model rests on: they're pure value types with no
MLX dependency, and the tests pin the invariant down, tags split across chunks included. No model in
the current lineup reasons — the one that did, LFM2.5-2.6B, was too slow on a phone to keep — so
this is dormant rather than dead: it's what the day one returns will need. Only
`answer` is ever written back. A block that never closes is reasoning to the last character, so such
a run yields *no* answer — and `AppModel.usableAnswer` refuses to write an empty one, because
replacing a paragraph with half a thought (or with nothing) is worse than leaving it alone and
saying so.

**Which stage a transform is at.** A reasoning model spends its first stretch producing tokens that
aren't the answer, which from the outside looks like a stall. `AppModel.reasoningIDs` follows the
token stream — in on the first `.reasoning`, out on the first `.answer` — keyed by whatever the
screen is showing a placeholder for (recording, paragraph, node, document), so those placeholders
read **Thinking…** until the answer starts and **Transforming…** after. The phase is latched beside
the stream, so an ordinary token costs a comparison rather than a hop back to the main actor.

**Inbox tags (iOS).** `Recording.tag` holds a tag's **name**, not a reference into the list of them
(`AppSettings.inboxTags`, edited in Settings): the list is a setting the user rearranges, and an
entry shouldn't lose what it says about itself because a tag was renamed or dropped — a filter for
an orphaned tag simply appears alongside the configured ones for as long as entries carry it.
A tag also carries an ink: `InboxTagStyle` is name + `colorID`, stored as JSON under the same
defaults key the plain name list used (`data(forKey:)` and `stringArray(forKey:)` each answer nil
for what the other wrote, so the old list is read back and given colours rather than dropped). The
kit names the palette but defines none of it — it compiles for the Watch, which draws none of this —
so `WW.tagColor(_:)` in the app holds the light and dark versions.
Automatic filing is `InboxTag.autoTag(for:from:)`, which compares *stems*: lowercase, letters only,
then endings taken off repeatedly and never below three characters, so "Questions", "Fixed" and
"Reminders" file where you'd expect while "Fixture" doesn't land under "Fix". It's the **first word**
only — a tag in the middle of a sentence is a word in a sentence. It runs from `AppModel.transcribe`
*after* the Auto transform (what the entry ends up saying is what files it) and never over a tag
already set by hand, and again in `importText(_:intoInbox:)`, since text arrives already
"transcribed" and never passes the transcription path at all.

**Joint documents (iOS).** A document and a graph shown at once are *two documents and a link*,
not a third kind of container. `Document.joinedID` is stored on one half only — the one the pair was
made from — and `DocumentStore.jointPartnerID(of:)` answers from either side, so no caller has to
know which half it holds. Everything a document has stays where it was: two sets of recordings, two
Auto transform choices, two backup files, two `.wwdoc` exports. The half that's pointed *at* is left
out of the Documents list, the Watch's target list and the widget (`Document.jointFollowerIDs(in:)`,
the one rule all three read), because it's reached through the row of the half that points. So the
pairing is one optional id, and separating is clearing it — which is also what deleting or trashing
either half does on its way out, so a survivor never points at something that isn't there.
A pair is *always* a document and a graph, and both `jointPartnerID(of:)` and `jointFollowerIDs(in:)`
require that: a link to something missing, or to another of the same kind, routes nothing and hides
nothing. An early build could write one — `createJointCounterpart` took the lead's index *before*
inserting the counterpart at the front, and the insert shifted it, so the link landed on whichever
document sat above it — which showed up as a stranger being "joined" and the pair opening onto
"Joint document not found". The index is now taken after the insert, and `dropImpossibleJoints()`
clears any such link at load, since nobody should have to go looking for it by hand.
`JointDocumentView` puts each half in a `NavigationStack` of its own, which is what lets
`DocumentDetailView` and `GraphDocumentView` go in unchanged and keep the title and **⋯** menu they
have everywhere else; without it both toolbars would pile into the one bar above and fight over it.
Which pane is where is decided by kind, not by which half came first.

**One stack, and only one.** `AnyNavigationPath.Error.comparisonTypeMismatch` is SwiftUI meeting two
kinds of navigation in one place, with a `try!` — so it takes the app down rather than picking one.
The joint view walked into it twice. First by *pushing* itself with
`navigationDestination(isPresented:)` inside a stack already driven by a typed `[Route]` path: a
boolean push puts an element in that path the typed binding can't represent. Then, with the push
gone, by giving each pane a `NavigationStack` of its own — nested inside that same typed stack,
which is the same mismatch by another route.

So: nothing pushes the pair and nothing nests. `Route.document(id)` asks the store, each time it
resolves, whether that document has a partner, so making a pair from inside a half turns that half
into the split view and separating turns it back. And a pane is told it's `isEmbedded`, which makes
it float the **⋯** menu it would have put in a navigation bar over its own top-right corner
(`paneMenu(for:)`) and put *nothing* in the bar above — which is also what keeps the two halves from
fighting over that bar. Both halves' menus come out of one `menuContent(for:)` either way, so the
floating menu and the toolbar can't drift apart; the rename that lived in the tappable title moves
into the menu when embedded, since there's no title there to tap. The divider between the panes is a
16-point grab strip whose drag writes a fraction to `@AppStorage` — `jointSplitAcross` and
`jointSplitDown`, two settings because how you like an iPad's columns says nothing about how you
like a phone's rows — clamped so neither half can be left under a fifth of the screen and
unrecoverable. Which halves are shown at all is a third remembered setting (`jointViewMode`,
`JointViewMode`), driven by the three-part toggle the *pair* floats in the top-right corner, clear
of the pane's own ⋯ by that button's width: document only, split, graph only. A hidden half is not
rendered rather than sized to nothing, so it isn't holding the keyboard or running a canvas nobody
is looking at — the cost is that it opens re-centred, which is the right state for a pane that has
just changed size anyway. On a phone the document half also moves its Auto transform strip off the bottom and
into the list (`AutoTransformBar`, split out of `CaptureBar` for exactly this), where it scrolls
away instead of spending a shared screen on furniture.

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
  The line itself is a **cubic Bézier**: the anchor comes back with the direction its side faces,
  and the control point at each end runs that way before turning, so the curve leaves and arrives
  square-on to the card exactly where the straight line used to. Each end's control reaches half the
  gap measured *along its own axis* (clamped to 16…90), so two cards facing each other across the
  standard 150-point gap have their controls meet in the middle — a clean S, with neither end
  overshooting the other. The "+" that inserts a node on an edge sits at the curve's own midpoint,
  `B(0.5)` — which for a cubic is `(P₀ + 3C₁ + 3C₂ + P₃) / 8` — since half way along the straight
  line between two cards isn't on the curve at all once it bends.
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
  where the node is. The links between the dots are the canvas's *own* curves — `GraphEdgeLine`
  values handed to the minimap and run through its projection, control points and all — so the map
  bends where the canvas bends. They're left out of the map's `==` on purpose: they're a function of
  the same positions, so nothing can change them without changing the nodes, and comparing them
  would repaint a map that (drawn from stored positions) doesn't move during a drag anyway. The map
  carries a card's **colour** and a group's **ring** for the same reason it carries the curves: a
  colour that means something on the canvas has to mean it here, or the map is a picture of the
  wrong graph. The rings come in as plain rectangles (`minimapRings`), measured from *stored*
  positions and without the canvas's nesting gap — that gap exists so two rings read as one inside
  the other, and at this size the pair is a single line either way.
- **A drag is one edit, measured in a space that isn't moving.** The live translation stays in view
  state and is written to the nodes only when the finger lifts, so dragging a branch doesn't rewrite
  the document (and its Markdown mirror) once per frame. Like pinning, positions don't bump
  `updatedAt` — where a node sits is layout, not an edit. The gesture reads `.global`, deliberately:
  a `DragGesture` measures against the coordinate space of the view it's attached to, and a node
  drag *moves that view*, so a local-space translation comes back halved and oscillating — the card
  flickers between the finger and half way there, and never lands on the node you were aiming at.
- **One drag, three meanings, decided once.** What a card drag *is* — a move, an **unlink** (⌘) or a
  **copy** (⌥) — is read from the modifiers at the first frame and kept in `dragMode` for the rest of
  the gesture, so a thumb slipping off a key half way across the canvas can't change what's
  happening. Only a plain move looks for a drop target: a card being pulled out of the tree, or a
  copy pulled out of one, shouldn't land straight back in it. An unlink carries the picked cards
  *without* their branches (unlinking joins each one's parent and children to each other, so the
  branch stays where it is and stays whole) and runs `unlinkNode` **as the drag begins**, not when
  it ends: the card has to be seen coming away while the finger is still moving, rather than a whole
  drag reading as an ordinary move and only turning out to be a detachment once it's over. A drag
  onto another card also carries the **auto tidy** the drop owes its new siblings
  (`autoTidyChildren(of:)`), since hanging a branch off a node changes that row exactly as adding a
  child does. Positions are
  committed. A copy is made **at the start** of the drag rather than at the end — `duplicateNodes`
  appends the copies over their originals and the drag moves *them*, which is what makes the gesture
  read as pulling a duplicate out. That's also why the drag tracks `dragSourceID` (the card whose
  gesture is firing) separately from `draggingNodeID` (the card actually moving): under ⌥ they're
  different nodes. A copy keeps links *inside* the copied set and drops links out of it, and takes
  no `recordingID` — a node owns its clip (`deleteNode` takes the audio with it), so a copy pointing
  at the same one would delete the original's audio out from under it.
- **Arrangement happens when asked — or, with Auto tidy on, every time a row of children changes**,
  and from one number. `DocumentStore.standardNodeGap` is
  the clear space this canvas leaves between two nodes *sideways*; the child column and the push
  that makes room for an inserted node are derived from it, so a tidied child, a new child and a
  dropped branch all land the same distance out. Down the page it's `tidyRowGap`, which is 30 —
  a column of siblings reads as a list, and 150 points between them is a column you scroll rather
  than read. That gap is between the **cards**: `tidyChildren` and `attachNode` take the heights the
  canvas has measured (`nodeSizes`, handed in as `heights:`) and fall back to `nodeCardHeight`, so a
  six-line card takes the room it needs instead of overlapping the sibling below it. An insert on an
  edge pushes by a node's worth *along that link's own axis* — a card's width sideways, a card's
  height downwards — for the same reason.
  `DocumentStore.tidyChildren(of:in:)` is the one thing that moves nodes the user didn't drag:
  children into a column beside their parent, spaced by the *height of the branch hanging off each*
  so a child with a family doesn't land on its sibling.
  Inserting a node on an edge is the same idea in miniature — the branch below slides out by a
  node's width and the new node takes the middle of the widened gap, so it has the room the "+" had.
  Both go through one rigid `translate(subtreeOf:)`, which is why nothing below ever gets scrambled.
  **Auto tidy** (the toggle at the minimap's right, stored app-wide as `graphAutoTidy` for the same
  reason the minimap's own switch is) simply calls that same tidy from every place a node is added
  with a parent, and from the one place an abandoned empty node is removed again. It has one rule of
  its own: a node made while a gesture is still running — a "+" held down, a chain still being
  spoken — puts its tidy in `pendingTidyParents` and it runs when the touch ends, because the card is
  what's recording and it must not move out from under the finger. The pending parents are then
  tidied in the order the graph stores them, which is the order they were made, so a chain lines up
  from the top down rather than each tidy undoing the last.
- **One press, read five ways.** A single `DragGesture(minimumDistance: 0)` decides between pan,
  selection box, hold-to-record, tap and double-tap, rather than stacking recognisers that would
  fight over the same touch. A *held* finger is always a recording — a root node under the finger,
  wherever it lands — which is the one gesture the canvas can't afford to make conditional, since
  it's the record button. Selecting is asked for instead: the ⌘ button beside the minimap held down
  (`ModifierKeyMonitor.virtualCommand`), or the mode from ⋯ → Select Nodes (`isSelecting`) for hands
  that would rather not hold anything. Either way a drag draws the box and a tap picks a card out;
  the "+" buttons stand down while it's on, so a stray fingertip can't add a node in the middle of
  choosing them. With a keyboard attached, **holding a real ⌘ turns a single drag into a selection
  box** as well. Two predicates, two mechanisms, because they answer different questions.
  `pickingOutThisTouch` reads `UIEvent.modifierFlags` off the touch itself (`CommandKeyWatcher`) —
  enough for a drag, and it works on every version. `isPickingOut` is view *state*, because the
  cards have to be drawn differently while the key is down and the quick actions appear under a
  pointer with nothing touched at all; that needs the press itself. SwiftUI has nothing for this on
  iOS — `onModifierKeysChanged` is macOS-only — and the responder chain is the wrong shape, since
  presses go to whatever is first responder (a text view, or nothing). So `ModifierKeyMonitor` reads
  GameController's keyboard, which reports the state of the keys on the device rather than of a
  focused view; one shared instance, since a joint document has two canvases asking about one
  keyboard. It watches `leftAlt`/`rightAlt` alongside `leftGUI`/`rightGUI`, since ⌥ has to be drawn
  as it's held too — it's what a copy drag reads, and what a document's inter-paragraph "+" reads to
  become a caret. It watches shift too, for one question only: a `UITextView` is handed the same
  `"\n"` whether or not shift was down, and a graph node's editor needs to tell **Return** (which
  commits, the same as Done) from **shift + Return** (which puts a line break in). With no hardware
  keyboard all of them stay false, which is what the ⌘ and ⌥ buttons are for — and those buttons
  live on the *same* shared monitor (`virtualCommand` / `virtualOption`) rather than in the canvas
  that draws them, because a joint document is two panes of one screen: a soft ⌘ held beside the
  canvas has to turn the document half's "+" into a caret, exactly as the real key does. Hover is tracked on every card in every mode rather than only while picking out: a
  pointer already resting on a card has sent its hover event and won't send another when ⌘ goes
  down. A card's quick actions **don't** go away the moment the pointer leaves it: the bar floats
  clear of the card, so reaching it means crossing a few points that belong to neither, and letting
  go there left a bar you could see and never press. The hover is held for `quickActionsGrace`, and
  the bar's own `onHover` (or the next card's) calls the clock off.
  And `registerTap` leaves the selection alone while picking out — a tap on a card reaches
  this gesture too, and clearing there undid the card's own toggle a frame later, which is why
  picking a second node used to leave only the second node. A tap that follows
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

**Reading the ⌘ and ⌥ keys (iOS 17).** SwiftUI's `onModifierKeysChanged` is iOS 18, and the app runs
from 17, so the keys are read the way UIKit has always offered them: a `UIEvent` carries the
modifier flags that were held when it happened. `CommandKeyWatcher` puts one passive
`UIGestureRecognizer` on the
window — it records `event.modifierFlags` in `touchesBegan` and immediately fails itself, with
`cancelsTouchesInView = false`, so it observes every touch without taking part in one. The flags
land in a `ModifierKeys` **class** rather than `@State` on purpose: a SwiftUI gesture closure sees
the view as it was when the body was last evaluated, so a key pressed between two frames of a drag
would be missed, and nothing about a key going down should redraw the canvas anyway. The cost of
reading them at touch-down is that ⌘ arms a *drag*, not a tap: ⌘-tapping a card to add it to the
selection would need the flag to be live in the body, which is what the ⌘ button (a real mode) is
for.

**Keyboard shortcuts on the canvas.** Delete, ⌘←, ⌘→ and ⌘T go through `GraphKeyCommands`, a
zero-sized `UIView` that becomes first responder and answers `keyCommands` — UIKit's mechanism
rather than SwiftUI's `onKeyPress`, because the responder chain already answers "is the user
typing?": a text view that takes first responder gets the keys instead, which is exactly right when
a node is open for editing. `isActive` says the same thing from the other end (no open editor, menu,
alert or recording sheet, and the canvas still on screen — a pushed-over screen leaves it in the
hierarchy, and Delete must not take cards off a canvas nobody is looking at), and it's acted on only
when it *changes* — asserting first responder on every update would drag the keyboard back from the
document half of a joint document each time the canvas redrew. The delete keys are matched by character (`\u{8}` backspace, `\u{7F}` forward delete)
rather than by a named constant, and every command sets `wantsPriorityOverSystemBehavior` so the
system doesn't keep the arrows for focus movement.

**Keeping a drag cheap (iOS).** A drag writes its translation to view state on every frame, so the
whole canvas body re-runs sixty times a second — which is fine only if one pass is linear in the
size of the graph. It wasn't: `Document.node(with:)` is a scan of the array, and every edge end,
every ring and every card looked its own nodes up again, so a pass was quadratic. `content(for:)`
now takes one pass (`cardBoxes`) that gives every node's drawn rectangle, and the edges, the group
rings and the cards are all handed rectangles out of it; `point(of:)` takes a `GraphNode` wherever
the caller already has one. The minimap is `Equatable` and drawn through `.equatable()`, since
dragging a node changes neither the stored positions nor the viewport it draws — comparing is much
cheaper than repainting every dot. What's left, if it's ever still not smooth, is splitting the node
card into its own view so SwiftUI can skip the ones a drag isn't touching.

**A gesture on a view that takes no touches never starts.** A group's ring is deliberately deaf
(`allowsHitTesting(false)`) so it isn't a dead zone over every node inside it, and only four strips
at its edge take touches. The drag lives on those strips now; attached to the ring as a whole it
never fired, which is why dragging a group did nothing until the finger came off. The ring's colour
wash is deaf in the same way, and — like a node card's — it's a view that comes and goes rather than
one always present at zero opacity, so taking a colour off actually takes the wash away.

**Rings are measured together, not one at a time.** `groupRings(in:boxes:)` returns every ring's
rectangle *and* the order to draw them in, because a **nested** group changes the ring around it:
two groups measured from the same outermost cards would otherwise land exactly on top of each other.
Rings are worked out innermost first (fewest members first — a strict subset is nested by
definition) and each is pushed out to clear the rings inside it by `nestedGroupGap`; they're then
drawn widest first, so an inner ring's edge and label sit above the outer one's rather than under
it. Membership is deliberately *not* judged against these frames: a node dragged into a ring is
tested against the plain bounding box of the members that didn't move, so a buffer drawn for the eye
can't quietly change what a group contains. What the rings *do* answer live is the drag itself —
`liveMembers(of:boxes:)` counts a dragged card in while its middle is inside the ring, so the ring
stretches to take it in as you carry it across and letting go confirms what you were looking at
rather than surprising you. It runs the same test the drop does, which is what keeps the two in
step.

**Two shapes for one list (iOS).** `showingNodeList` is the *request*; how it's answered depends on
the width. `horizontalSizeClass == .regular` puts the node list in an `HStack` beside the canvas as a
300-point sidebar (the canvas simply gets narrower, and `canvasSize` follows through the
`GeometryReader` it already had, so centring stays right); anything compact keeps the sheet, whose
binding is `showingNodeList && !showsNodeSidebar`. One list body (`nodeList(for:)`) serves both.
Tapping a row closes only the sheet — the sidebar covers nothing, so there's nothing to get out of
the way — and both flash `highlightedNodeID`, which `nodeBorder` reads: the ring is drawn by the
card itself, wherever it happens to be, and a `Task` clears it after `highlightDuration`, cancelling
any flash still running so an old timer can't put the new ring out early.

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
A document's paragraphs and an Inbox entry are set at the chosen size itself — one setting, one
size, wherever text is read top-to-bottom — while a node card sits two points under it, being a card
pinned to fixed canvas coordinates rather than a line of running text.

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
