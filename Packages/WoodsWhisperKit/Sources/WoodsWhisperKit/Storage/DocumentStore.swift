import Foundation

/// Persists `Document`s (each containing `Recording`s), their audio files, and `PromptPreset`s.
/// iOS/iPadOS only — the Watch keeps its own flat `RecordingStore`.
@MainActor
public final class DocumentStore: ObservableObject {
    @Published public private(set) var documents: [Document] = []
    @Published public private(set) var trash: [Document] = []
    @Published public private(set) var presets: [PromptPreset] = []

    /// Mirrors the documents' text into a folder the user picks in Settings. Off (and inert) until
    /// a folder is chosen; every save below schedules a sync through it.
    public let backup = LocalBackupStore()

    private let baseURL: URL
    private let audioDirURL: URL
    private let documentsURL: URL
    private let trashURL: URL
    private let presetsURL: URL

    /// Title used for the auto-created container that receives Watch recordings.
    public static let inboxTitle = "Inbox"

    public init(directoryName: String = "Library") {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        baseURL = support.appendingPathComponent(directoryName, isDirectory: true)
        audioDirURL = baseURL.appendingPathComponent("audio", isDirectory: true)
        documentsURL = baseURL.appendingPathComponent("documents.json")
        trashURL = baseURL.appendingPathComponent("trash.json")
        presetsURL = baseURL.appendingPathComponent("presets.json")
        try? FileManager.default.createDirectory(at: audioDirURL, withIntermediateDirectories: true)
        load()
    }

    // MARK: Audio paths

    /// The audio file backing `recording`. A text-only entry (imported text, no capture) has none:
    /// the URL returned for one deliberately names a file that can't exist rather than resolving to
    /// the audio *directory*, so a `fileExists` check answers "no" instead of "yes, it's a folder".
    public func audioURL(for recording: Recording) -> URL {
        guard !recording.isTextOnly else {
            return audioDirURL.appendingPathComponent("\(recording.id.uuidString).noaudio")
        }
        return audioDirURL.appendingPathComponent(recording.audioFileName)
    }

    /// A fresh URL to record into. Caller records audio here, then calls `addRecording`.
    public func newAudioURL(id: UUID = UUID()) -> (id: UUID, url: URL, fileName: String) {
        let fileName = "\(id.uuidString).m4a"
        return (id, audioDirURL.appendingPathComponent(fileName), fileName)
    }

    // MARK: Documents

    @discardableResult
    public func createDocument(title: String = "New Document",
                               kind: Document.Kind = .document) -> Document {
        let doc = Document(title: title, kind: kind)
        documents.insert(doc, at: 0)
        persistDocuments()
        return doc
    }

    public func rename(_ document: Document, to title: String) {
        guard let idx = index(of: document.id) else { return }
        documents[idx].title = title
        touch(idx)
    }

    /// Pin or unpin a document. Pinning deliberately does not bump `updatedAt` (the pin is metadata,
    /// not an edit); the Documents list surfaces pinned documents at the top.
    public func setPinned(_ pinned: Bool, for documentID: UUID) {
        guard let idx = index(of: documentID) else { return }
        guard documents[idx].isPinned != pinned else { return }
        documents[idx].isPinned = pinned
        persistDocuments()
    }

    /// Choose (or clear, with nil) the transform run automatically the first time a recording in this
    /// document is transcribed — the "Auto transform" toggle at the bottom of the Inbox and of each
    /// document. Like pinning, this is metadata rather than an edit, so it doesn't bump `updatedAt`.
    public func setAutoTransform(_ presetID: UUID?, for documentID: UUID) {
        guard let idx = index(of: documentID) else { return }
        guard documents[idx].autoTransformPresetID != presetID else { return }
        documents[idx].autoTransformPresetID = presetID
        persistDocuments()
    }

    /// Ordered, lightweight snapshots of the user's documents (Inbox excluded), pinned first then by
    /// most-recently-updated — the list pushed to the Watch as record targets.
    public var documentDescriptors: [DocumentDescriptor] {
        Self.descriptors(from: documents)
    }

    /// The pinned-first, most-recent-next document descriptor ordering, as a pure function so callers
    /// observing the `documents` publisher can compute it from a freshly-published array.
    public static func descriptors(from documents: [Document]) -> [DocumentDescriptor] {
        documents
            .filter { $0.title != Self.inboxTitle }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
            .map(DocumentDescriptor.init)
    }

    public func delete(_ document: Document) {
        if let idx = index(of: document.id) {
            for recording in documents[idx].recordings { removeAudio(recording) }
        }
        documents.removeAll { $0.id == document.id }
        persistDocuments()
    }

    public func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            for recording in documents[index].recordings { removeAudio(recording) }
            documents.remove(at: index)
        }
        persistDocuments()
    }

    // MARK: Trash

    public func moveToTrash(_ document: Document) {
        documents.removeAll { $0.id == document.id }
        trash.insert(document, at: 0)
        persistDocuments()
        persistTrash()
    }

    public func restoreFromTrash(_ document: Document) {
        trash.removeAll { $0.id == document.id }
        documents.insert(document, at: 0)
        persistTrash()
        persistDocuments()
    }

    public func permanentlyDelete(_ document: Document) {
        for recording in document.recordings { removeAudio(recording) }
        trash.removeAll { $0.id == document.id }
        persistTrash()
    }

    public func emptyTrash() {
        for document in trash {
            for recording in document.recordings { removeAudio(recording) }
        }
        trash.removeAll()
        persistTrash()
    }

    public func document(with id: UUID) -> Document? {
        documents.first { $0.id == id }
    }

    /// The container that receives incoming Watch recordings, created on demand.
    @discardableResult
    public func inboxDocument() -> Document {
        if let existing = documents.first(where: { $0.title == Self.inboxTitle }) {
            return existing
        }
        let inbox = Document(title: Self.inboxTitle)
        documents.append(inbox)            // keep at the bottom; user docs surface on top
        persistDocuments()
        return inbox
    }

    // MARK: Recordings within a document

    /// Add a recording to a document. If `audioData` is provided (e.g. from the Watch), it is
    /// written to the audio directory; otherwise the audio is assumed already on disk at
    /// `audioURL(for:)` (e.g. recorded in place via `newAudioURL`).
    public func addRecording(_ recording: Recording,
                             audioData: Data? = nil,
                             toDocument documentID: UUID) {
        if let audioData {
            try? audioData.write(to: audioURL(for: recording), options: .atomic)
        }
        guard let idx = index(of: documentID) else { return }
        documents[idx].recordings.append(recording)
        adoptIntoGraph(recording, at: idx)
        touch(idx)
    }

    /// A clip that lands in a **graph** document needs somewhere to be, so it's given a node of its
    /// own — unless one already points at it, which is the canvas's own hold-to-record (there the
    /// node exists from the moment the finger goes down, and the clip catches up on release).
    ///
    /// This is what lets a Watch capture, a shared audio file, or a recording moved in from the
    /// Inbox arrive in a graph without any of those paths knowing graphs exist. The node starts
    /// with whatever transcript came with the clip — usually none, in which case `AppModel` fills
    /// it in the moment transcription finishes.
    private func adoptIntoGraph(_ recording: Recording, at idx: Int) {
        guard documents[idx].isGraph,
              !documents[idx].nodes.contains(where: { $0.recordingID == recording.id }) else { return }
        let text = recording.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        documents[idx].nodes.append(GraphNode(text: text,
                                              position: documents[idx].nextRootPosition(),
                                              recordingID: recording.id))
    }

    /// Drop any node's link to a recording that has just left this document (deleted or moved
    /// away). The node keeps its words — they're its own copy — but stops offering to play, revise
    /// or re-transcribe a clip that isn't there any more.
    private func unlinkNodes(from recordingIDs: Set<UUID>, at idx: Int) {
        guard documents[idx].isGraph else { return }
        for nodeIdx in documents[idx].nodes.indices {
            if let id = documents[idx].nodes[nodeIdx].recordingID, recordingIDs.contains(id) {
                documents[idx].nodes[nodeIdx].recordingID = nil
            }
        }
    }

    public func updateRecording(_ recording: Recording, inDocument documentID: UUID) {
        guard let docIdx = index(of: documentID),
              let recIdx = documents[docIdx].recordings.firstIndex(where: { $0.id == recording.id })
        else { return }
        documents[docIdx].recordings[recIdx] = recording
        touch(docIdx)
    }

    public func renameRecording(_ recordingID: UUID, inDocument documentID: UUID, to name: String) {
        guard let docIdx = index(of: documentID),
              let recIdx = documents[docIdx].recordings.firstIndex(where: { $0.id == recordingID })
        else { return }
        documents[docIdx].recordings[recIdx].name = name
        touch(docIdx)
    }

    public func deleteRecording(_ recordingID: UUID, fromDocument documentID: UUID) {
        guard let docIdx = index(of: documentID),
              let recIdx = documents[docIdx].recordings.firstIndex(where: { $0.id == recordingID })
        else { return }
        removeAudio(documents[docIdx].recordings[recIdx])
        documents[docIdx].recordings.remove(at: recIdx)
        unlinkNodes(from: [recordingID], at: docIdx)
        touch(docIdx)
    }

    /// Move a recording (and its audio, which stays at the same path) to another document.
    public func moveRecording(_ recordingID: UUID, from sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              let srcIdx = index(of: sourceID),
              let recIdx = documents[srcIdx].recordings.firstIndex(where: { $0.id == recordingID }),
              let dstIdx = index(of: targetID)
        else { return }
        let recording = documents[srcIdx].recordings.remove(at: recIdx)
        unlinkNodes(from: [recordingID], at: srcIdx)
        documents[dstIdx].recordings.append(recording)
        adoptIntoGraph(recording, at: dstIdx)
        documents[srcIdx].updatedAt = Date()
        touch(dstIdx)
    }

    /// Reorder recordings within a single document (drag-to-rearrange in the Recordings section).
    public func moveRecordings(in documentID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let idx = index(of: documentID) else { return }
        documents[idx].recordings.move(fromOffsets: offsets, toOffset: destination)
        touch(idx)
    }

    /// Reorder within just the subset of recordings matching `isRevision`, so the "Recordings" and
    /// "Revisions" sections reorder independently while sharing one underlying array. The moved
    /// elements stay in their subset's slots; the other subset is left untouched.
    public func moveRecordings(in documentID: UUID, isRevision: Bool,
                               from offsets: IndexSet, to destination: Int) {
        guard let idx = index(of: documentID) else { return }
        var all = documents[idx].recordings
        let slots = all.indices.filter { all[$0].isRevision == isRevision }
        var subset = slots.map { all[$0] }
        subset.move(fromOffsets: offsets, toOffset: destination)
        for (slot, element) in zip(slots, subset) { all[slot] = element }
        documents[idx].recordings = all
        touch(idx)
    }

    /// Replace a recording's audio file and reset its transcript (used by "Re-record"). The old
    /// audio is removed; the caller has already written the new audio at `newFileName`.
    public func replaceRecordingAudio(_ recordingID: UUID, in documentID: UUID,
                                      newFileName: String, duration: TimeInterval) {
        guard let docIdx = index(of: documentID),
              let recIdx = documents[docIdx].recordings.firstIndex(where: { $0.id == recordingID })
        else { return }
        let old = documents[docIdx].recordings[recIdx]
        if old.audioFileName != newFileName { removeAudio(old) }
        documents[docIdx].recordings[recIdx].audioFileName = newFileName
        documents[docIdx].recordings[recIdx].duration = duration
        documents[docIdx].recordings[recIdx].transcript = nil
        documents[docIdx].recordings[recIdx].status = .pending
        touch(docIdx)
    }

    // MARK: Batch operations (selection mode)

    public func deleteRecordings(_ ids: Set<UUID>, fromDocument documentID: UUID) {
        guard let docIdx = index(of: documentID) else { return }
        for recording in documents[docIdx].recordings where ids.contains(recording.id) {
            removeAudio(recording)
        }
        documents[docIdx].recordings.removeAll { ids.contains($0.id) }
        unlinkNodes(from: ids, at: docIdx)
        touch(docIdx)
    }

    /// Pin or unpin several documents at once (the Documents list's batch Pin). Like the
    /// single-document `setPinned`, this deliberately does not bump `updatedAt` — the pin is
    /// metadata, not an edit — and it persists once for the whole batch.
    public func setPinned(_ pinned: Bool, for ids: Set<UUID>) {
        var changed = false
        for idx in documents.indices where ids.contains(documents[idx].id) {
            guard documents[idx].isPinned != pinned else { continue }
            documents[idx].isPinned = pinned
            changed = true
        }
        guard changed else { return }
        persistDocuments()
    }

    /// Move several documents to the trash at once (the Documents list's batch Delete), keeping
    /// their relative order at the top of the trash and persisting once.
    public func moveToTrash(_ ids: Set<UUID>) {
        let moving = documents.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        documents.removeAll { ids.contains($0.id) }
        trash.insert(contentsOf: moving, at: 0)
        persistDocuments()
        persistTrash()
    }

    public func moveRecordings(_ ids: Set<UUID>, from sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              let srcIdx = index(of: sourceID),
              let dstIdx = index(of: targetID) else { return }
        // Order the moved batch chronologically so a new document assembled from several selected
        // clips reads oldest-first (matching the order they were recorded), not selection order.
        let moving = documents[srcIdx].recordings
            .filter { ids.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        guard !moving.isEmpty else { return }
        documents[srcIdx].recordings.removeAll { ids.contains($0.id) }
        unlinkNodes(from: Set(moving.map(\.id)), at: srcIdx)
        documents[dstIdx].recordings.append(contentsOf: moving)
        for recording in moving { adoptIntoGraph(recording, at: dstIdx) }
        documents[srcIdx].updatedAt = Date()
        touch(dstIdx)
    }

    // MARK: Document body (paragraphs)

    /// Append a paragraph to the bottom of the body (e.g. from "Re-transcribe").
    public func appendParagraph(_ text: String, to documentID: UUID) {
        guard let idx = index(of: documentID) else { return }
        documents[idx].paragraphs.append(Document.Paragraph(text: text))
        touch(idx)
    }

    /// Append several paragraphs to the bottom of the body in one go (a text import), persisting
    /// once for the whole batch rather than once per paragraph.
    public func appendParagraphs(_ paragraphs: [Document.Paragraph], to documentID: UUID) {
        guard !paragraphs.isEmpty, let idx = index(of: documentID) else { return }
        documents[idx].paragraphs.append(contentsOf: paragraphs)
        touch(idx)
    }

    /// Insert a paragraph at `position` in the body (used by the inter-paragraph "+" button).
    public func insertParagraph(_ text: String, at position: Int, in documentID: UUID) {
        guard let idx = index(of: documentID) else { return }
        let clamped = max(0, min(position, documents[idx].paragraphs.count))
        documents[idx].paragraphs.insert(Document.Paragraph(text: text), at: clamped)
        touch(idx)
    }

    public func updateParagraph(_ paragraphID: UUID, in documentID: UUID, to text: String) {
        guard let docIdx = index(of: documentID),
              let pIdx = documents[docIdx].paragraphs.firstIndex(where: { $0.id == paragraphID })
        else { return }
        documents[docIdx].paragraphs[pIdx].text = text
        touch(docIdx)
    }

    /// Replace a paragraph with the result of splitting `text` on blank lines — so paragraph breaks
    /// introduced while editing (or produced by a transform) become separate sections, each with its
    /// own inter-paragraph insert button. An empty result removes the paragraph.
    public func replaceParagraph(_ paragraphID: UUID, in documentID: UUID, withTextSplitInto text: String) {
        guard let docIdx = index(of: documentID),
              let pIdx = documents[docIdx].paragraphs.firstIndex(where: { $0.id == paragraphID })
        else { return }
        let replacements = Document.paragraphs(from: text)
        if replacements.isEmpty {
            documents[docIdx].paragraphs.remove(at: pIdx)
        } else {
            documents[docIdx].paragraphs.replaceSubrange(pIdx...pIdx, with: replacements)
        }
        touch(docIdx)
    }

    public func deleteParagraph(_ paragraphID: UUID, in documentID: UUID) {
        guard let docIdx = index(of: documentID) else { return }
        documents[docIdx].paragraphs.removeAll { $0.id == paragraphID }
        touch(docIdx)
    }

    public func moveParagraphs(in documentID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let docIdx = index(of: documentID) else { return }
        documents[docIdx].paragraphs.move(fromOffsets: offsets, toOffset: destination)
        touch(docIdx)
    }

    /// Replace the entire body with new paragraphs (used by a whole-document transform).
    public func setParagraphs(_ paragraphs: [Document.Paragraph], in documentID: UUID) {
        guard let idx = index(of: documentID) else { return }
        documents[idx].paragraphs = paragraphs
        touch(idx)
    }

    // MARK: Graph body (nodes)

    public func addNode(_ node: GraphNode, to documentID: UUID) {
        guard let idx = index(of: documentID) else { return }
        documents[idx].nodes.append(node)
        touch(idx)
    }

    /// Write a node's text back (the in-place editor's Done, a transform's result, a transcript
    /// arriving). Stored trimmed, so "has this node anything to say?" is the same question
    /// everywhere.
    public func setNodeText(_ nodeID: UUID, in documentID: UUID, to text: String) {
        guard let docIdx = index(of: documentID),
              let nodeIdx = documents[docIdx].nodes.firstIndex(where: { $0.id == nodeID })
        else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard documents[docIdx].nodes[nodeIdx].text != trimmed else { return }
        documents[docIdx].nodes[nodeIdx].text = trimmed
        touch(docIdx)
    }

    /// Point a node at the clip it was spoken into — or at nothing (`nil`), which is what "Revise"
    /// does before it records a replacement.
    public func linkNode(_ nodeID: UUID, toRecording recordingID: UUID?, in documentID: UUID) {
        guard let docIdx = index(of: documentID),
              let nodeIdx = documents[docIdx].nodes.firstIndex(where: { $0.id == nodeID }),
              documents[docIdx].nodes[nodeIdx].recordingID != recordingID
        else { return }
        documents[docIdx].nodes[nodeIdx].recordingID = recordingID
        touch(docIdx)
    }

    /// Write settled positions back — from a finished drag, or from the layout once it has come to
    /// rest. Like pinning, where a node *sits* is metadata rather than an edit, so this doesn't bump
    /// `updatedAt`: nudging a branch around shouldn't re-sort the Documents list.
    public func moveNodes(_ positions: [UUID: GraphPoint], in documentID: UUID) {
        guard !positions.isEmpty, let idx = index(of: documentID) else { return }
        var changed = false
        for nodeIdx in documents[idx].nodes.indices {
            guard let position = positions[documents[idx].nodes[nodeIdx].id],
                  documents[idx].nodes[nodeIdx].position != position else { continue }
            documents[idx].nodes[nodeIdx].position = position
            changed = true
        }
        guard changed else { return }
        persistDocuments()
    }

    /// Re-parent a node — and with it everything hanging off it — which is what dropping one node
    /// onto another does. Refuses a move that would make a node its own ancestor: that leaves a
    /// cycle, and a cycle is a graph no outline can walk out of.
    @discardableResult
    public func reparentNode(_ nodeID: UUID, to newParentID: UUID?, in documentID: UUID) -> Bool {
        guard let docIdx = index(of: documentID),
              let nodeIdx = documents[docIdx].nodes.firstIndex(where: { $0.id == nodeID }),
              documents[docIdx].nodes[nodeIdx].parentID != newParentID
        else { return false }
        if let newParentID {
            guard newParentID != nodeID,
                  documents[docIdx].nodes.contains(where: { $0.id == newParentID }),
                  !documents[docIdx].isAncestor(nodeID, of: newParentID)
            else { return false }
        }
        documents[docIdx].nodes[nodeIdx].parentID = newParentID
        touch(docIdx)
        return true
    }

    /// Hang a node — and everything under it — off a new parent, and put the branch where a child
    /// of that parent belongs: out at the standard distance, below the siblings it's joining, and
    /// clear of anything else that happens to be in the way.
    ///
    /// This is what a drop does. Re-parenting alone would leave the branch wherever the finger let
    /// go of it, which is usually right on top of its new parent — the line would say one thing and
    /// the layout another.
    @discardableResult
    public func attachNode(_ nodeID: UUID, to parentID: UUID, in documentID: UUID) -> Bool {
        guard reparentNode(nodeID, to: parentID, in: documentID),
              let docIdx = index(of: documentID),
              let parent = documents[docIdx].node(with: parentID),
              let node = documents[docIdx].node(with: nodeID)
        else { return false }

        let moving = Set(documents[docIdx].subtree(of: nodeID))
        let siblings = documents[docIdx].children(of: parentID).filter { !moving.contains($0.id) }

        // Below the branches already hanging there, or level with the parent if it had none.
        var y = parent.position.y
        if !siblings.isEmpty {
            let bottom = siblings
                .flatMap { documents[docIdx].subtree(of: $0.id) }
                .compactMap { documents[docIdx].node(with: $0)?.position.y }
                .max()
            if let bottom { y = bottom + Self.tidyRowGap }
        }

        let dx = parent.position.x + Self.childColumnOffset - node.position.x
        var dy = y - node.position.y
        for _ in 0..<Self.placementAttempts {
            guard collides(subtree: moving, movedByX: dx, y: dy, at: docIdx) else { break }
            dy += Self.tidyRowGap
        }
        translate(subtreeOf: nodeID, byX: dx, y: dy, at: docIdx)
        touch(docIdx)
        return true
    }

    /// Whether a branch, moved by `(dx, dy)`, would come down on top of any node outside it.
    private func collides(subtree moving: Set<UUID>, movedByX dx: Double, y dy: Double,
                          at docIdx: Int) -> Bool {
        let others = documents[docIdx].nodes.filter { !moving.contains($0.id) }
        guard !others.isEmpty else { return false }
        for id in moving {
            guard let node = documents[docIdx].node(with: id) else { continue }
            let x = node.position.x + dx
            let y = node.position.y + dy
            for other in others {
                if abs(other.position.x - x) < Self.nodeFootprintWidth,
                   abs(other.position.y - y) < Self.nodeFootprintHeight {
                    return true
                }
            }
        }
        return false
    }

    /// Delete one node. Its children are promoted to its own parent rather than deleted along with
    /// it — a branch is usually worth more than the node it happens to hang from, and deleting them
    /// one at a time is possible where un-deleting a subtree isn't.
    ///
    /// The clip the node was spoken into goes with it: a graph has no Recordings list, so the node
    /// was the only way to reach that audio, and leaving it behind would be weight nobody could see
    /// or delete.
    public func deleteNode(_ nodeID: UUID, in documentID: UUID) {
        guard let docIdx = index(of: documentID),
              let nodeIdx = documents[docIdx].nodes.firstIndex(where: { $0.id == nodeID })
        else { return }
        let node = documents[docIdx].nodes.remove(at: nodeIdx)
        for idx in documents[docIdx].nodes.indices
        where documents[docIdx].nodes[idx].parentID == nodeID {
            documents[docIdx].nodes[idx].parentID = node.parentID
        }
        if let recordingID = node.recordingID,
           let recIdx = documents[docIdx].recordings.firstIndex(where: { $0.id == recordingID }) {
            removeAudio(documents[docIdx].recordings[recIdx])
            documents[docIdx].recordings.remove(at: recIdx)
        }
        touch(docIdx)
    }

    /// Add a child to `parentID` — the "+" on a node's right edge. It starts to the right of its
    /// parent and below any siblings; the layout takes it from there.
    @discardableResult
    public func addChildNode(to parentID: UUID, in documentID: UUID, text: String = "") -> GraphNode? {
        guard let docIdx = index(of: documentID),
              let parent = documents[docIdx].node(with: parentID) else { return nil }
        let siblings = documents[docIdx].children(of: parentID).count
        let node = GraphNode(text: text,
                             parentID: parentID,
                             position: GraphPoint(x: parent.position.x + Self.childColumnOffset,
                                                  y: parent.position.y + Double(siblings) * 100))
        documents[docIdx].nodes.append(node)
        touch(docIdx)
        return node
    }

    /// Add a node *between* an existing parent and child — the "+" halfway along the line joining
    /// them — and hand the child (with its branch) to it.
    ///
    /// The gap widens to make room, and the new node takes the middle of the widened gap, so it
    /// ends up with as much space on either side as the "+" had: the branch below slides out by a
    /// node's worth, the new node by half that. Nothing on this canvas moves by itself, so room
    /// that isn't made here is never made at all — the new card would simply land on top of the two
    /// it went between.
    @discardableResult
    public func insertNode(between parentID: UUID, and childID: UUID, in documentID: UUID) -> GraphNode? {
        guard let docIdx = index(of: documentID),
              let parent = documents[docIdx].node(with: parentID),
              let childIdx = documents[docIdx].nodes.firstIndex(where: { $0.id == childID }),
              documents[docIdx].nodes[childIdx].parentID == parentID
        else { return nil }
        let child = documents[docIdx].nodes[childIdx]

        var midX = (parent.position.x + child.position.x) / 2
        var midY = (parent.position.y + child.position.y) / 2

        let dx = child.position.x - parent.position.x
        let dy = child.position.y - parent.position.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > 0.01 {
            let pushX = dx / distance * Self.insertedNodeSpacing
            let pushY = dy / distance * Self.insertedNodeSpacing
            translate(subtreeOf: childID, byX: pushX, y: pushY, at: docIdx)
            // Half of what the branch moved: the midpoint of the gap as it now stands.
            midX += pushX / 2
            midY += pushY / 2
        }

        let node = GraphNode(parentID: parentID, position: GraphPoint(x: midX, y: midY))
        documents[docIdx].nodes[childIdx].parentID = node.id
        documents[docIdx].nodes.append(node)
        touch(docIdx)
        return node
    }

    /// "Tidy children": line a node's children up in a column beside it — all the same distance
    /// out, evenly spaced down the page, centred on the parent — and bring each one's branch along
    /// unchanged.
    ///
    /// Siblings are spaced by the *height of the branch hanging off them* rather than by a flat
    /// gap, so a child with a family of its own doesn't land on top of the next one. Their order is
    /// the order they already read in, top to bottom, so tidying rearranges the spacing and not the
    /// meaning.
    public func tidyChildren(of parentID: UUID, in documentID: UUID) {
        guard let docIdx = index(of: documentID),
              let parent = documents[docIdx].node(with: parentID) else { return }
        let children = documents[docIdx].children(of: parentID)
        guard !children.isEmpty else { return }

        // How far each child's branch reaches above and below the child itself.
        let reaches = children.map { child -> (above: Double, below: Double) in
            let ys = documents[docIdx].subtree(of: child.id).compactMap { id in
                documents[docIdx].node(with: id)?.position.y
            }
            let top = ys.min() ?? child.position.y
            let bottom = ys.max() ?? child.position.y
            return (child.position.y - top, bottom - child.position.y)
        }

        let bands = reaches.reduce(0.0) { $0 + $1.above + $1.below }
        let height = bands + Double(children.count - 1) * Self.tidyRowGap
        var cursor = parent.position.y - height / 2
        let column = parent.position.x + Self.childColumnOffset

        for (child, reach) in zip(children, reaches) {
            let y = cursor + reach.above
            translate(subtreeOf: child.id,
                      byX: column - child.position.x,
                      y: y - child.position.y,
                      at: docIdx)
            cursor = y + reach.below + Self.tidyRowGap
        }
        touch(docIdx)
    }

    /// Move a node and everything hanging off it, rigidly — the one way this store ever moves a
    /// branch, so a tidy or an insert never scrambles what's below.
    private func translate(subtreeOf nodeID: UUID, byX dx: Double, y dy: Double, at docIdx: Int) {
        guard dx != 0 || dy != 0 else { return }
        for id in documents[docIdx].subtree(of: nodeID) {
            guard let idx = documents[docIdx].nodes.firstIndex(where: { $0.id == id }) else { continue }
            documents[docIdx].nodes[idx].position.x += dx
            documents[docIdx].nodes[idx].position.y += dy
        }
    }

    /// How far the branch below is pushed out to make room for a node inserted above it — a card's
    /// width and a little air.
    private static let insertedNodeSpacing: Double = 200

    /// How far out a child is placed from its parent, centre to centre: a card's width plus 200
    /// points of clear space between the two, which is what "give them room" comes to once the
    /// cards themselves are accounted for. Used by "Tidy children", by a brand-new child, and by a
    /// node dropped onto a new parent, so all three agree on what "beside its parent" means.
    static let childColumnOffset: Double = 380
    /// Air between one child's branch and the next one's.
    private static let tidyRowGap: Double = 120

    /// Roughly how much canvas a node card takes up, for keeping placed branches off each other.
    /// The view draws them 180 points wide; the rest is the margin worth leaving.
    private static let nodeFootprintWidth: Double = 210
    private static let nodeFootprintHeight: Double = 96
    /// How many slots down to try before giving up and dropping the branch where it lands.
    private static let placementAttempts = 12

    // MARK: Sharing (Woods Whisper document files)

    /// Pack a document — its edited body, its recordings' metadata/transcripts, and every recording's
    /// audio — into a single `.wwdoc` file in a temporary directory, returning its URL for sharing.
    public func exportArchive(for documentID: UUID) throws -> URL {
        guard let doc = document(with: documentID) else { throw DocumentArchiveError.documentNotFound }

        var audio: [String: Data] = [:]
        for recording in doc.recordings where !recording.isTextOnly {
            if let data = try? Data(contentsOf: audioURL(for: recording)) {
                audio[recording.audioFileName] = data
            }
        }
        let archive = DocumentArchive(document: doc, audio: audio)
        let payload = try archive.encoded()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoodsWhisperExports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(safeFileName(for: doc.title)).\(DocumentArchive.fileExtension)")
        try payload.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Unpack a `.wwdoc` file into a brand-new document. The imported copy is fully independent: it
    /// gets a fresh document id and each recording's audio is rewritten to a fresh filename so it
    /// never aliases (or gets deleted alongside) an existing document's audio — even on a round-trip
    /// back to the device that exported it. Returns the newly inserted document.
    @discardableResult
    public func importArchive(from url: URL) throws -> Document {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let archive = try DocumentArchive.decode(from: data)

        var importedRecordings: [Recording] = []
        for var recording in archive.document.recordings {
            // A text-only entry has no file to rewrite — giving it a fresh audio name would turn it
            // into an audio recording whose clip is permanently missing.
            guard !recording.isTextOnly else {
                importedRecordings.append(recording)
                continue
            }
            let ext = (recording.audioFileName as NSString).pathExtension
            let newFileName = "\(UUID().uuidString).\(ext.isEmpty ? "m4a" : ext)"
            if let bytes = archive.audio[recording.audioFileName] {
                try? bytes.write(to: audioDirURL.appendingPathComponent(newFileName), options: .atomic)
            }
            recording.audioFileName = newFileName
            importedRecordings.append(recording)
        }

        // Kind and nodes ride along with the body, so a graph shared from another device opens as a
        // graph — laid out exactly as it was drawn there.
        let imported = Document(title: archive.document.title,
                                kind: archive.document.kind,
                                paragraphs: archive.document.paragraphs,
                                nodes: archive.document.nodes,
                                recordings: importedRecordings)
        documents.insert(imported, at: 0)
        persistDocuments()
        return imported
    }

    /// Strip characters that are illegal (or awkward) in a file name so a document title can be used
    /// as the exported file's name. (Shared with the Markdown backup mirror, which names its files
    /// the same way.)
    private func safeFileName(for title: String) -> String {
        MarkdownBackup.safeFileName(title, fallback: "Document")
    }

    // MARK: Local backup

    /// Adopt the folder the user picked in Settings and immediately populate it.
    public func setBackupFolder(_ url: URL) throws {
        try backup.setFolder(url)
        backUpNow()
    }

    /// Stop backing up. Files already written stay where they are.
    public func clearBackupFolder() {
        backup.clearFolder()
    }

    /// Write the Markdown mirror now, skipping the change-coalescing delay. Used when the folder is
    /// first chosen, at launch, and by Settings' "Back Up Now". A no-op when backup is off.
    public func backUpNow() {
        backup.syncNow(documents: documents, inboxTitle: Self.inboxTitle)
    }

    // MARK: Presets

    public func add(preset: PromptPreset) { presets.append(preset); persistPresets() }

    public func update(preset: PromptPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx] = preset
        persistPresets()
    }

    /// Insert a new preset or replace the existing one with the same id. The editor uses this so
    /// saving never depends on a separate "is new" flag being correct — a brand-new preset that
    /// (for any reason) reached `update`'s "not found" path would previously be silently dropped.
    public func save(preset: PromptPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
        persistPresets()
    }

    public func delete(preset: PromptPreset) {
        presets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    public func resetBuiltInPresets() {
        let custom = presets.filter { !$0.isBuiltIn }
        presets = PromptPreset.builtIns + custom
        persistPresets()
    }

    // MARK: Helpers

    private func index(of id: UUID) -> Int? { documents.firstIndex { $0.id == id } }

    private func touch(_ idx: Int) {
        documents[idx].updatedAt = Date()
        persistDocuments()
    }

    private func removeAudio(_ recording: Recording) {
        guard !recording.isTextOnly else { return }   // nothing on disk behind an imported-text entry
        try? FileManager.default.removeItem(at: audioURL(for: recording))
    }

    // MARK: Persistence

    /// Bump when the shipped built-in presets change, so existing installs re-seed them (custom
    /// presets are preserved) instead of keeping the old set forever.
    private static let presetsSeedVersion = 2
    private let presetsSeedVersionKey = "ww.presetsSeedVersion"

    private func load() {
        if let data = try? Data(contentsOf: documentsURL),
           let decoded = try? JSONDecoder.iso.decode([Document].self, from: data) {
            documents = decoded.sorted { $0.updatedAt > $1.updatedAt }
        }
        if let data = try? Data(contentsOf: trashURL),
           let decoded = try? JSONDecoder.iso.decode([Document].self, from: data) {
            trash = decoded
        }
        let defaults = UserDefaults.standard
        if let data = try? Data(contentsOf: presetsURL),
           let decoded = try? JSONDecoder.iso.decode([PromptPreset].self, from: data),
           !decoded.isEmpty {
            presets = decoded
            // Migrate the built-in set to the current ones when behind (keeps user presets).
            if defaults.integer(forKey: presetsSeedVersionKey) < Self.presetsSeedVersion {
                resetBuiltInPresets()
                defaults.set(Self.presetsSeedVersion, forKey: presetsSeedVersionKey)
            }
        } else {
            presets = PromptPreset.builtIns
            persistPresets()
            defaults.set(Self.presetsSeedVersion, forKey: presetsSeedVersionKey)
        }
        // Seed the widget's snapshot at launch too, so it has data on installs/updates that
        // predate the widget (persistDocuments only runs on the next actual edit).
        WidgetSnapshotStore.update(documents: documents, inboxTitle: Self.inboxTitle)
    }

    /// The single choke point every document mutation runs through — and so the one place the
    /// Markdown backup and the widget snapshot need to hook into for "refresh on every creation
    /// or edit".
    private func persistDocuments() {
        if let data = try? JSONEncoder.iso.encode(documents) {
            try? data.write(to: documentsURL, options: .atomic)
        }
        backup.scheduleSync(documents: documents, inboxTitle: Self.inboxTitle)
        WidgetSnapshotStore.update(documents: documents, inboxTitle: Self.inboxTitle)
    }

    private func persistTrash() {
        guard let data = try? JSONEncoder.iso.encode(trash) else { return }
        try? data.write(to: trashURL, options: .atomic)
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder.iso.encode(presets) else { return }
        try? data.write(to: presetsURL, options: .atomic)
    }
}
