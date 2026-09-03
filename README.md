# Woods Whisper

Offline voice capture, transcription, and text transformation for **iOS / iPadOS / watchOS**.

Record audio on your Apple Watch or your iPhone/iPad, transcribe it to text **entirely
on-device** with NVIDIA **Parakeet TDT v3** (via CoreML/ANE), then reshape that text with a
lightweight on-device **LFM2.5** model (Liquid AI) driven by reusable prompt presets.

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
   (CoreML/ANE); LFM2.5 runs via [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm).
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
- **Inbox gestures.** **Tap** an entry to read the whole thing: the row opens out to every line of
  the transcript, and tapping again folds it back to a few. **Double-tap** to edit it — **in place**,
  where it sits (see *Editing in place* below). **Swipe left** for **Move** (into a document) and
  **Delete**; **swipe right** for **Tag**, **Copy** and **Transform**. Long-press still enters batch
  selection.
- **Tags.** An Inbox entry can be filed under a tag — **Question**, **Reminder**, **Fix** to start
  with, each in its own colour, and the list is yours to edit in **Settings → Inbox Tags** (tap a
  tag's swatch to change its colour; a new tag takes the first colour none of the others is wearing). Two ways in: swipe an entry right
  and tap **Tag**, or simply *say* it — an entry whose **first word is a tag** files itself the
  moment it's transcribed. It's forgiving about how you said it ("Questions…", "Fixed…", "Reminders…"
  all count) and strict about where: a tag has to open the entry, not turn up in the middle of a
  sentence. A transform runs first, so what the entry ends up saying is what files it, and a tag you
  chose by hand is never overruled. Once anything is filed, a row of tags appears across the top of
  the Inbox — tap one to see just those, tap it again for everything. While you're looking at one
  tag, **Copy All**, **New Document** and **Delete All** appear at the bottom — no plate under them,
  floating over the page the way the record button does — because everything on screen is then one
  kind of thing. **New Document** is the one that earns the filter: it names a document after the
  tag (change it if you like), moves every entry under that tag into it with their audio, and seeds
  the body with what they said, leaving the Inbox clear of them. Entries keep the tag they were
  filed under even if you later drop it from the Settings list.
- **Moving an entry into a document.** Swipe an Inbox entry left → **Move** (or select several and
  tap **Move**) and the pane that slides up leads with **New Document**, *above* the list of existing
  documents — it's the destination that's always there, so it no longer sits below however many
  documents you've got. Pick it, name the document, and the entries move across with their text
  seeded into the body.
- **A line break makes a section.** Text the app itself produced — a transcript, a transform's
  answer — becomes **one paragraph per line** when it lands in a document body. So an Inbox entry a
  transform broke into lines (a list, a set of points) arrives as the sections it reads as, each with
  its own inter-paragraph **"+"**, its own swipe actions, and its own place in the reorder — rather
  than as one block with the breaks buried inside it. It holds wherever that text reaches a body: a
  new document seeded from the Inbox, a clip recorded straight into a document, **Append** /
  **Re-transcribe**, and a whole-document or paragraph transform. Text *you* wrote keeps the other
  rule — blank lines split, a single line break you typed stays inside its paragraph.
- **Editing in place.** Editing never opens a sheet over what you're reading. Double-tap an Inbox
  entry (or a paragraph in a document, or swipe it right → **Edit**) and *that block* becomes the
  editor: an outlined box that grows with the text, in the type it was already set in, everything
  around it left where it was. The actions sit along the bottom of that same box, inside the
  outline — a compressed row of icons at the **left**, **Done** at the **right**. For an Inbox entry
  the icons are **Copy / Share / Transform / Reset** (Share hands off either the text or the audio
  clip); for a paragraph they're **Revise / Insert / Transform**. **Done** saves and closes; blank
  lines you added split the block into separate paragraphs (a single line break you typed stays
  inside the paragraph — it's text the *app* wrote that splits on every line).
- **The "+" between sections.** The thin rule with a **"+"** at its middle, under every paragraph,
  records a clip and drops its transcript in at that spot. Hold **⌘** and
  the glyph becomes a caret: tap it then and you get an **empty section to type into**, opened for
  editing where it sits — the same thought the graph canvas answers with a double-tap, for the times
  what you're adding isn't worth saying aloud. "Hold ⌘" means the key with a keyboard attached, or —
  in a **joint document**, where the graph half draws one — the **⌘ button beside the minimap**: a
  soft key is a key, and a key held on one side of a split screen is held on both.
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
  words back. And it **says nothing when it can't run**: with an online model chosen and no signal —
  the woods, aeroplane mode — the clip simply keeps its plain transcription, and the reason is in
  **Settings → Log** rather than in an alert over what you were doing. A rewrite that couldn't
  happen because you're off-grid is this app working as promised, not an error. (A transform you
  *asked* for still tells you when it fails: you're waiting on an answer, and you should know none
  is coming.)
- **Graph documents (experimental).** The **✎** button now asks what you're making: a **Document** or
  a **Graph**. A graph is a mind map on a pannable, zoomable canvas over a very light grid — endless
  in every direction, so there's always more room a drag away. **Hold anywhere on the canvas** and a
  node appears under your finger and starts recording — a short **tick** under your finger says so,
  since a hold gives no other sign the app heard it; lift and it stops, transcribes, and the words
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
  cards: **tap twice** to edit one in place — the row along the bottom of the open card opens with a
  **colour dot** and carries **Revise / Transform / Tidy Children**, and a red **trash** that
  deletes the node outright — or **long-press** for the actions a paragraph gets from a swipe (Edit,
  Add Child, Revise, Transform, Delete) as a dropdown. **Return closes an open card**: a node is a
  card rather than a page, so the key that ends a line ends the edit instead — exactly what **Done**
  does. **Shift + Return** puts a line break in for the times a card really does want two.
  **Drag** a node and its children
  come with it; **drop it on another node** and the whole branch hangs off that one — settling into
  place beside its new parent, below the children already there and clear of anything else. The
  lines joining them are **smooth curves**, leaving and arriving square-on to the side of the card
  they're attached to: a pair side by side reads as a straight line, one sitting high or low as an S
  rather than a diagonal cut across the gap. Nodes stay
  exactly where you put them — nothing rearranges them behind your back, though **Tidy Children**
  (in a node's edit bar, and in its long-press menu) will line a node's children up beside it on
  request, each with its own branch in tow, and **Auto Tidy** below will do it every time by itself.
  A card is never truncated: it's as tall as what was said into it, since a transcript cut off at
  six lines is a node you have to open to read. The **"+"** centred on a node's right edge — half in,
  half out, sitting on the seam a child grows from — adds a child, and the
  one midway along a line drops a node between the two it joins — evenly, with the same room either
  side, pushing the branch below out of the way; **tap** either to type, or **hold** either to
  record into the new node the way the canvas does. Whenever a hold is recording, the elapsed
  counter floats above your finger, clear of the node it's filling. Pinch to zoom, drag while
  pinching to move around at the same time, and let go mid-drag for the canvas to coast to a stop.
  There's no bottom bar at all — the hold is the record button, and a graph's auto transform is an
  app-wide setting (**Settings → Graphs**) rather than a per-document toggle — so the canvas runs
  all the way to the edge.
- **A colour for a card, and for a ring.** A **coloured dot** opens the palette in four places: at
  the head of a node's edit bar, in front of a group's name at the corner of its ring, in the
  **selection bar** (where it colours everything picked out at once), and in the group sheet, which
  lays the row of dots out inline. Pick one and the card (or the ring) takes that colour for its
  border and a wash of it behind — enough to tell two clusters apart across a canvas, faint enough
  to read over. The dot at the end of the row, crossed through, takes the colour off again. They're
  the same six inks an Inbox tag wears, so a colour means the same thing wherever you meet it.
- **Headings.** A node whose words begin with **#** is drawn large and bold, and one beginning with
  **##** a size under it. The marker itself is invisible on the canvas — you typed it to say "make
  this a heading", and the size is what it turned into — and comes back the moment you open the node
  to edit it. (Three hashes or more isn't a size the canvas draws, so it stays ordinary text with
  the hashes showing.)
- **Three keys and a toggle, around the minimap.** **⌘** and **⌥** stacked at the canvas's bottom
  left; **⇧** over **Auto Tidy** at the bottom right — all four there whether or not the minimap
  is, two to a side so neither stack stands taller than the map between them.
  Auto Tidy is a setting: tap it on and it stays on, which is why it sits apart from the keys.
  **⇧, ⌘ and ⌥ are keys**: hold one down with one thumb and drag with the other, exactly as you'd
  hold the real thing, and it lets go the moment you do. They fill in while they're on. Being keys,
  they reach as far as the real ones do: in a **joint document** the canvas's ⌘ turns the document
  half's **"+"** into a caret while it's held, the same as a keyboard's would. ⇧ means nothing on
  its own here — it only qualifies ⌘ — so it's greyed until ⌘ is down, and lets go of itself when ⌘
  does.
- **Auto Tidy.** With it on, adding a node lines its siblings up around it — **Tidy Children**, run
  for you rather than asked for, every time a row of children changes. **Dropping** a branch onto a
  node counts as changing that row, so a card hung off a parent lines its new siblings up as your
  finger leaves it, rather than sitting where it landed until you ask. Children go out beside their
  parent at the standard distance, stacked with **30 points of air between the cards** — measured
  between what's drawn, so a six-line card takes the room it needs and the gap stays the gap you
  see.
  **A tidy never turns a branch round.** Which way a row runs is something you said by putting the
  cards there, so it's read off the layout and kept: children drawn in a column to the right are
  re-spaced in a column to the right, children drawn in a row *underneath* are re-spaced in a row
  underneath, and the same for left and up. Tidying is about the spacing — the part nobody wants to
  do by hand — not about the direction. A card's **"+"** follows the same rule: it adds the new
  child to the row it's joining rather than always striking out to the right. (A parent with no
  children yet has no direction to read, so its first child goes out to the right, as always.)
  A node with no parent has no
  siblings to line up, so a root you hold or double-tap onto the canvas is left exactly where you put
  it; abandoning an empty node closes the row back up. A node made *during* a gesture — a **"+"**
  held down, a chain still being spoken — waits until your finger lifts, so the card being recorded
  into never slides out from under it. The toggle is remembered across graphs, like the minimap.
- **Picking several nodes out.** The hold belongs to recording, so selecting is asked for. Three ways
  in: **holding the ⌘ button** beside the minimap while you drag, **holding a real ⌘** and dragging
  if there's a keyboard attached, or **⋯ → Select Nodes** for a mode that stays on with nothing held.
  However you get there, a drag on the canvas draws a selection box — everything it touches is
  selected — and a tap on a card takes it in or out. While ⌘ is engaged, the card you **point at**
  (or tap) also raises a small pair of buttons just above it: **delete** that node, or **tidy its
  children** — the two things worth doing to *one* card. They stay up for a moment once you point
  away, so you can move onto them and press one. Pick out a second card and they stand down: a
  set of nodes is what the bar along the bottom is for. (Pointing needs a pointer, and a real ⌘ needs
  a real keyboard — without either, the ⌘ button beside the minimap is the way in and a tap does the
  pointing.) Any one of the
  selected nodes drags the whole lot, and a bar along the bottom carries what you can do with them;
  **Done** leaves the mode.
- **Lining a selection up.** That bar's second row has **Align Left**, **Align Top**, **Distribute
  Horizontal** and **Distribute Vertical**. Aligning puts every selected card's left (or top) edge
  on the leftmost (or topmost) one; distributing holds the two on the ends where they are and evens
  out the gaps between the rest — gaps between the *cards*, so a tall one doesn't crowd its
  neighbours. Only the selected nodes move; their children stay where they are. Distributing needs
  three cards to mean anything, so with two it's greyed.
- **With a keyboard attached.** **Delete** removes the selected cards. **⌘←** and **⌘→** line them
  up by their left or right edges — the right-hand one isn't in the bar, since four buttons is
  already a row, but the keyboard has a side for each. **⌘T** tidies: the selected cards' children,
  or, with nothing picked out, every row in the graph from the roots down. None of them fire while
  you're typing into a node — the keys belong to the text then.
- **Groups.** Select a few nodes and tap **Group**: a dashed ring is drawn round them, and it
  follows them wherever they go. A sheet opens on the new ring — its **name**, its **colour**, and
  **Ungroup** — and tapping the name at a ring's corner opens the same one again. The **dot** beside
  the name colours it without opening anything. Drag the ring's **edge** to move everything inside —
  the members, and whatever hangs off them, since a child follows its parent whoever picked the
  parent up. Drag a node **into** the ring and it joins: the ring stretches to take it in as you
  carry it across, and letting go is a confirmation of what you were already looking at. Nothing an
  ordinary drag does takes a node back *out* — a branch travelling with its parent, or a card
  re-settled by a drop, keeps every group it belongs to — so leaving is asked for: **⌘ + drag** the
  card clear of the ring, the same gesture that takes it out of the network. A ring left with fewer
  than two nodes dissolves itself. The **edge** is the only part of a ring that takes a touch — its
  middle is deaf, so the cards inside stay as reachable as they were — so with a pointer, resting on
  that edge draws it **solid and brighter**: the ring says where you can take hold of it before you
  press to find out.
  A group **nested** inside another is drawn with 10 points of air between the two rings, so one
  reads as being inside the other rather than the pair reading as one thick line.
- **⌘ + drag takes a node out.** Hold ⌘ (the real one, or the button beside the
  minimap) and drag a card: it comes away from the tree **the moment the drag starts** — its parent
  and its children are joined to each other, so the branch survives — and it floats free where you
  drop it, still saying what it said. You watch it leave rather than finding out afterwards. Drag it
  clear of a **group's ring** and it leaves that too: ⌘ is the one gesture for "take this out of
  what it's in", whether what it's in is the tree or a ring. It's the whole of what the old scissors
  button did, as the gesture you'd reach for anyway. Drag several selected cards and they all come
  out.
- **⌘ + ⇧ + drag takes it out of the group only.** The same gesture with **⇧** added leaves the
  tree alone: the card keeps its parent and its children, carries its branch the way an ordinary
  drag does, and the only thing it sheds is a ring you carry it clear of. Two ways to belong, and
  this is how you drop one without the other. (⇧ *softens* ⌘ rather than adding to it, so the more
  final of the two is the one you get by holding less.)
- **⌥ + drag leaves a copy behind.** Hold ⌥ instead and what comes away is a *copy* — of the card,
  of the whole selection, or of a group, ring and all — appearing over the original and travelling
  with your finger. The copy is unlinked from what it came out of, though links *inside* what you
  copied survive, so a cluster keeps its shape. It carries the words but not the recording behind
  them: the clip stays with the node that was spoken into.
- **Finding your way around a graph.** A **minimap** can sit along the bottom, the keys at its
  left and Auto Tidy at its right — **off to begin with**, since the canvas's whole point is that it
  runs to the edge and a map of a graph you can already see is a strip of screen spent on nothing;
  **⋯ → Show Minimap** turns it on and it stays on. It draws every node as a dot **in the colour
  that card is drawn in**,
  every parent-to-child link as a hairline between two of them, every **group** as its own dashed
  ring in its own ink, all
  inside a box showing what's on screen — the same curves the canvas draws, so the map carries the
  shape of the graph and not just where the nodes happen to have fallen. A colour means the same
  thing on the map as on the canvas, which is what lets you find a cluster there rather than only
  recognise one. Touch or drag it to go there. The **⋯** menu adds **List
  Nodes** (the graph as an indented list, in outline order), **Center Graph**, and the switch for
  the minimap itself. The same menu's **Copy Outline** / **Share
  Outline** — and the backup folder — hand over the graph as a **Markdown outline**: one bullet per
  node, indented by depth, in the order the canvas reads.
- **The node list, beside the canvas or over it.** On an **iPad** — any wide screen — **List Nodes**
  opens as a **sidebar down the right**: tap a line and the canvas slides to that node with the list
  still open, ready for the next one. Nothing is covered, so nothing has to close. On a **phone** it
  stays a sheet over the canvas, and tapping a line closes it, since it's covering the answer. Either
  way the node you picked **rings itself in amber** for a moment when the canvas arrives — amber
  precisely because nothing else on a card is: it says "this is the one you asked for" rather than
  "this one is selected".
- **Record straight to a document from the Watch.** The iPhone syncs your document list to the Watch
  over WatchConnectivity; swipe left on the Watch's record screen to pick a target document (or the
  Inbox). The chosen target's name shows on the record screen, and clips captured there are filed into
  that document on the iPhone/iPad instead of the Inbox. (Targets sync over the paired-iPhone path; the
  direct-to-iPad transports still file into the Inbox.)
- **Record into a document from the list.** Every row in **Documents** carries a **"+"** just left
  of its open arrow — the graph canvas's button, on a list row. **Hold** it and recording starts
  where you are — the same tick confirms it — and let go and it stops, transcribes itself, and lands
  in that document: one more paragraph at the end of an ordinary document, or a new root node in a
  graph. The row shows the counter while you hold. (**Tap** it rather than holding and it simply opens the document.) Record
  before the speech model has finished loading and the clip just waits its turn — it's transcribed
  and filed into the document by itself the moment the model is ready, this launch or the next.
- **Joint documents.** A document and a graph, open at the same time — prose down one side, a mind
  map down the other. The **⋯** menu of either one offers **Create Joint Document**: it makes the
  half you haven't got, under the same title, and opens the two together. On an **iPad** they sit
  side by side (document left, graph right, the document opening at a third of the width); on a
  **phone**, stacked with the **graph on top** — it's panned and pinched with a whole hand — and the
  document below it, where the keyboard comes up from anyway.
  **Drag the divider** to give one half more room; where you leave it is where it opens next time
  (across and down are remembered separately). Not every moment wants both halves, so a **three-part
  toggle** sits at the right-hand end of the pair's own **navigation bar** — the way back to
  Documents at its left, this at its right: **document only**, **split**, **graph only**. Writing
  wants the page and mapping wants the canvas — and on a phone, where the two share the height,
  either one alone is most of what's worth having. It's a statement about the whole screen, which is
  why it sits in the screen's own bar rather than inside one of the panes; each half still floats
  its **⋯** over its own corner below. Like the divider it's remembered: what you were last looking
  at is how the next pair opens. Each
  half stays an ordinary document throughout — its
  own recordings, its own Auto transform, its own backup file, and its own **⋯** menu floating in
  the top-right corner of its pane (no titles: the row you tapped already said what this is, so
  **Rename** moves into that menu) — so nothing about either of them changes by being paired. On a
  **phone**, where two panes share the height, the document half's **Auto transform** strip moves
  off the bottom and into the list, under the Copy / Share / Edit / Transform row. The **"+"** on a joint document's row
  records into the **document** half: a clip spoken at a list row is a thought to write down, and it
  lands as a paragraph at the end rather than as a node somewhere on the canvas nobody chose. The
  pair takes one row in **Documents**, counting what's in both. **Separate Joint Document**, in
  either half's menu, ends it: both survive with everything in them, and the second one takes its own
  place in the list. Deleting either half separates the pair on its way out.
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
- **Text size.** **Settings → Display → Text Size** sets how big transcriptions are drawn, with a
  sample line under the slider so you can see what you're choosing. **A document's paragraphs and an
  Inbox entry are set at exactly that size** — one setting, one size, wherever text is read
  top-to-bottom; a graph node stays two points under it, being a card pinned to a canvas rather than
  a line of running text. The in-place editors read the same number, so text never changes size the
  moment you tap it.
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
| Text rewrite  | **LFM2.5 1.2B Instruct**      | MLX Swift  | iPhone / iPad      |
|               | Claude Sonnet 4.6 / Haiku 4.5 (online, selectable) | Anthropic API | cloud (needs signal) |

**Speech model.** Parakeet TDT v3 is the default — most accurate and multilingual. The smaller
**Whisper** variants (tiny/base/small) are lighter, faster downloads; pick one in
**Settings → Speech Model** if you prefer Whisper or want a smaller footprint.

**Language model.** On-device it's Liquid AI's **LFM2.5 1.2B Instruct** (~0.7 GB, 4-bit via MLX) —
small and quick, which is what tidying a transcript wants. It downloads once while online and is
reloaded automatically from cache on subsequent launches (no need to re-tap Download); see
**Settings → Language Model**. (The 2.6B was offered alongside it for a while. It reasons before
answering, which on a phone meant a long wait for no better a result, so it was dropped — and its
weights are deleted from the device on the next launch.)

Should a model that reasons ever be back, the app is ready for it: a `<think>…</think>` block is
split off as it streams and **never reaches your text** — what's saved is the answer alone, shown in
a collapsible **Reasoning** section instead — the placeholder reads **Thinking…** until the answer
starts, and a run that never gets past thinking writes nothing at all rather than replacing your
words with half a thought.

**Online models (optional).** When you have a cell signal, you can instead pick **Claude Sonnet
4.6** or **Claude Haiku 4.5** from the same picker. These stream from Anthropic's API rather than
running on-device, so there's nothing to download — instead the **Download** button becomes
**Authenticate** (or **Edit Authentication** once a key is saved). Tap it, paste an Anthropic API
key (from console.anthropic.com), and it's stored in the device Keychain and sent only to
Anthropic. Recording and transcription stay fully on-device; only the rewrite step of a cloud
model leaves the device, and only when one is selected — the offline models remain the default.
