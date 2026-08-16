import SwiftUI
import WoodsWhisperKit
#if canImport(UIKit)
import UIKit
#endif

/// A **graph document**: a force-directed mind map on a pannable, zoomable canvas, as opposed to a
/// document's column of paragraphs.
///
/// • **Hold anywhere** on the canvas and a node appears under your finger and starts recording;
///   lift and it stops, transcribes, and the words drop into that node. One gesture, one node.
/// • **Double-tap** the canvas for a node you type into instead.
/// • A node is a small edit block: **tap twice** to edit it in place, **long-press** for the
///   actions a paragraph gets from a swipe, as a dropdown.
/// • **Drag** a node and its children come along; **drop it on another node** and the whole branch
///   hangs off that one instead.
/// • The **"+"** on a node's right edge adds a child; the one midway along a line inserts a node
///   between the two it joins.
///
/// There's no red record button along the bottom — the hold *is* the record button — but the Auto
/// transform toggle is the same one the Inbox and documents carry, and applies to nodes the same
/// way (see `AppModel.captureGraphNode`).
struct GraphDocumentView: View {
    @EnvironmentObject private var model: AppModel
    let documentID: UUID

    /// Live node positions and the relaxation that produces them. The canvas reads this rather than
    /// the stored positions, which are only written back once the graph settles.
    @StateObject private var layout = GraphLayoutEngine()

    /// The recorder behind hold-to-record. (Revise uses the ordinary `RecordingSheet` instead —
    /// replacing a node deliberately deserves the pause/discard controls.)
    @StateObject private var recorder = AudioRecorder()

    // Canvas transform. `pan` is where the canvas origin sits in view coordinates, `scale` the zoom.
    @State private var pan: CGPoint = .zero
    @State private var panOrigin: CGPoint?
    @State private var scale: CGFloat = 1
    @State private var zoomStart: ZoomStart?
    @State private var canvasSize: CGSize = .zero
    @State private var didPlaceCanvas = false

    // The finger on the bare canvas: pan, hold-to-record, or a tap.
    @State private var phase: CanvasPhase = .idle
    @State private var holdTask: Task<Void, Never>?
    @State private var recordingNodeID: UUID?
    @State private var lastTap: (at: Date, point: CGPoint)?

    // Node editing, in place, in its own card.
    @State private var editingNodeID: UUID?
    @State private var editingText = ""
    @State private var editingSelection = NSRange(location: 0, length: 0)

    // Node interaction: the long-press dropdown, a drag and where it would drop, and the transforms
    // running right now.
    @State private var menuNodeID: UUID?
    @State private var draggingNodeID: UUID?
    @State private var dropTargetID: UUID?
    @State private var transformTargetID: UUID?
    @State private var transformingNodeIDs: Set<UUID> = []
    @State private var reviseTask: ReviseTask?

    /// Measured card sizes, so a drop lands on the node it looks like it lands on and the "+" sits
    /// on the actual edge rather than an assumed one.
    @State private var nodeSizes: [UUID: CGSize] = [:]

    // Title, sharing.
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var shareItem: ShareItem?
    @State private var documentFileShare: DocumentFileShareItem?

    private var document: Document? { model.documents.document(with: documentID) }

    var body: some View {
        Group {
            if let document {
                canvas(for: document)
            } else {
                WWEmptyState(title: "Graph not found", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WW.paper)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(for: document) }
        // The same bottom strip as everywhere else, minus the red dot: on a graph, recording is the
        // hold on the canvas, and it places the node at the same time.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editingNodeID == nil {
                CaptureBar(presets: model.documents.presets,
                           selected: model.autoTransformPreset(for: documentID),
                           onSelect: { model.setAutoTransform($0, for: documentID) },
                           onRecord: nil)
            }
        }
        .onAppear {
            layout.onSettle = { positions in
                model.documents.moveNodes(positions, in: documentID)
            }
        }
        // Leaving commits the open editor and the settled layout, the way leaving a document commits
        // an open paragraph — and closes off a hold that never got its finger back (a gesture the
        // system cancelled, or a screen left mid-recording), which would otherwise leave the
        // recorder running behind a node that says "Recording" forever.
        .onDisappear {
            cancelHold()
            if recordingNodeID != nil { finishHoldRecording() }
            phase = .idle
            finishEditing()
            layout.stop()
        }
        .sheet(item: $reviseTask) { task in
            RecordingSheet(title: "Revise Node",
                           makeURL: { model.documents.newAudioURL().url }) { url, duration in
                model.captureGraphNode(audioURL: url, duration: duration,
                                       nodeID: task.nodeID, in: documentID)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.text])
        }
        .sheet(item: $documentFileShare) { item in
            ActivityView(activityItems: [item.url])
        }
        .alert("Rename graph", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let document, !trimmed.isEmpty { model.documents.rename(document, to: trimmed) }
            }
            Button("Cancel", role: .cancel) { }
        }
        // One node's Transform, from the dropdown or from inside the open editor.
        .confirmationDialog("Transform — \(AppSettings.shared.model.shortName)",
                            isPresented: Binding(get: { transformTargetID != nil },
                                                 set: { if !$0 { transformTargetID = nil } }),
                            titleVisibility: .visible) {
            if let id = transformTargetID {
                ForEach(model.documents.presets) { preset in
                    Button(preset.name) { runTransform(preset, nodeID: id) }
                }
            }
        }
    }

    // MARK: The canvas

    @ViewBuilder
    private func canvas(for document: Document) -> some View {
        GeometryReader { geo in
            content(for: document)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background(alignment: .topLeading) { GraphGrid(pan: pan, scale: scale) }
                .background(WW.paper)
                .clipped()
                .contentShape(Rectangle())
                // The canvas's own gestures. A touch that lands on a node is the node's — SwiftUI
                // gives a child's gesture priority over its ancestors' — so this only ever sees the
                // bare canvas.
                .gesture(canvasGesture())
                .simultaneousGesture(zoomGesture())
                .overlay(alignment: .topLeading) { menuOverlay(for: document, in: geo.size) }
                .overlay {
                    if document.nodes.isEmpty {
                        WWEmptyState(title: "An empty canvas",
                                     systemImage: "point.3.connected.trianglepath.dotted",
                                     message: "Hold anywhere to record a node — it appears where your finger is and stops when you lift it. Double-tap to type one instead.")
                    }
                }
                .onAppear {
                    canvasSize = geo.size
                    layout.sync(with: document)
                    placeCanvas(in: geo.size, document: document)
                }
                .onChange(of: geo.size) { _, size in canvasSize = size }
                // Nodes added, removed, or re-parented: the layout needs the new shape. Text and
                // positions change constantly and it doesn't care about either.
                .onChange(of: structureKey(of: document)) { _, _ in
                    if let latest = self.document { layout.sync(with: latest) }
                }
        }
    }

    /// Everything drawn in canvas coordinates: the lines, the "+" on each of them, and the nodes.
    /// One transform is applied to the lot — `scaleEffect` then `offset` — so a canvas point `c`
    /// lands at `c * scale + pan` and `canvasPoint(for:)` is its exact inverse.
    @ViewBuilder
    private func content(for document: Document) -> some View {
        let lines = edges(of: document)
        ZStack(alignment: .topLeading) {
            GraphEdgeShape(edges: lines)
                .stroke(WW.inkTertiary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .allowsHitTesting(false)

            ForEach(lines) { edge in
                GraphPlusButton { insertNode(on: edge) }
                    .accessibilityLabel("Insert node between")
                    .position(x: edge.midpoint.x + GraphCanvas.center,
                              y: edge.midpoint.y + GraphCanvas.center)
            }

            ForEach(document.nodes) { node in
                nodeView(node, in: document)
            }
        }
        .frame(width: GraphCanvas.extent, height: GraphCanvas.extent, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .offset(x: pan.x - GraphCanvas.center * scale, y: pan.y - GraphCanvas.center * scale)
    }

    // MARK: Nodes

    @ViewBuilder
    private func nodeView(_ node: GraphNode, in document: Document) -> some View {
        let isEditing = editingNodeID == node.id
        let center = point(of: node.id, in: document)
        let card = nodeCard(node, in: document, isEditing: isEditing)
            // The open editor is given a little more room than a card at rest: it has to hold the
            // text *and* the action row along the bottom of its outline.
            .frame(width: isEditing ? GraphCanvas.editingNodeWidth : GraphCanvas.nodeWidth,
                   alignment: .leading)
            .background { sizeReader(for: node.id) }
            .overlay(alignment: .trailing) {
                if !isEditing {
                    GraphPlusButton { addChild(to: node) }
                        .accessibilityLabel("Add child node")
                        .offset(x: 17)
                }
            }

        Group {
            if isEditing {
                // The open editor keeps every gesture to itself: a double tap selects a word, a long
                // press raises the selection handles, a drag moves the caret.
                card
            } else {
                card
                    .onTapGesture(count: 2) { startEditing(node) }
                    .onLongPressGesture(minimumDuration: 0.45) { openMenu(for: node) }
                    .gesture(nodeDrag(node, in: document))
            }
        }
        .position(x: center.x + GraphCanvas.center, y: center.y + GraphCanvas.center)
        .zIndex(isEditing || draggingNodeID == node.id ? 2 : 1)
    }

    /// A node: the same edit block a paragraph or an Inbox entry becomes, shrunk to a card.
    @ViewBuilder
    private func nodeCard(_ node: GraphNode, in document: Document, isEditing: Bool) -> some View {
        if isEditing {
            WWInlineEditBox(onDone: { finishEditing() }) {
                InlineTextEditor(text: $editingText, selection: $editingSelection, style: .graphNode)
            } actions: {
                WWInlineEditAction("Revise", "mic.fill") { reviseEditingNode() }
                WWInlineEditAction("Transform", "wand.and.stars", enabled: model.modelReady) {
                    transformEditingNode()
                }
            }
        } else {
            nodeLabel(node, in: document)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WW.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(nodeBorder(node), lineWidth: nodeBorderWidth(node)))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
    }

    /// What a node says while it isn't being edited: its words, or why it hasn't any yet.
    @ViewBuilder
    private func nodeLabel(_ node: GraphNode, in document: Document) -> some View {
        if recordingNodeID == node.id {
            HStack(spacing: 8) {
                Circle().fill(WW.ember).frame(width: 10, height: 10)
                Text(Recording.durationLabel(recorder.elapsed))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(WW.ink)
                Text("Recording")
                    .font(.caption)
                    .foregroundStyle(WW.inkSecondary)
            }
        } else if transformingNodeIDs.contains(node.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Transforming…").font(.caption).foregroundStyle(WW.inkSecondary)
            }
        } else if node.hasText {
            Text(node.trimmedText)
                .font(.subheadline)
                .foregroundStyle(WW.ink)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
        } else {
            switch recording(for: node, in: document)?.status {
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Transcribing…").font(.caption).foregroundStyle(WW.inkSecondary)
                }
            case .pending:
                Text("Waiting to transcribe").font(.caption).foregroundStyle(WW.inkSecondary)
            case .failed:
                Text("Transcription failed").font(.caption).foregroundStyle(WW.amber)
            case .done, .none:
                Text("Empty — tap twice to write")
                    .font(.caption)
                    .foregroundStyle(WW.inkTertiary)
            }
        }
    }

    private func nodeBorder(_ node: GraphNode) -> Color {
        if dropTargetID == node.id { return WW.moss }
        if recordingNodeID == node.id { return WW.ember }
        return WW.hairline
    }

    private func nodeBorderWidth(_ node: GraphNode) -> CGFloat {
        (dropTargetID == node.id || recordingNodeID == node.id) ? 2 : 1
    }

    private func recording(for node: GraphNode, in document: Document) -> Recording? {
        guard let id = node.recordingID else { return nil }
        return document.recordings.first(where: { $0.id == id })
    }

    /// Report each card's measured size so drops and the right-edge "+" line up with what's drawn.
    private func sizeReader(for id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { nodeSizes[id] = proxy.size }
                .onChange(of: proxy.size) { _, size in nodeSizes[id] = size }
        }
    }

    // MARK: Edges

    private func edges(of document: Document) -> [GraphEdgeLine] {
        document.nodes.compactMap { node in
            guard let parentID = node.parentID, document.node(with: parentID) != nil else { return nil }
            return GraphEdgeLine(id: node.id,
                                 parentID: parentID,
                                 from: point(of: parentID, in: document),
                                 to: point(of: node.id, in: document))
        }
    }

    /// Where a node is *right now*: the layout's live position while the canvas is open, falling
    /// back to the stored one for a node it hasn't adopted yet.
    private func point(of id: UUID, in document: Document) -> CGPoint {
        if let live = layout.points[id] { return CGPoint(x: live.x, y: live.y) }
        guard let node = document.node(with: id) else { return .zero }
        return CGPoint(x: node.position.x, y: node.position.y)
    }

    /// What the layout needs to be told about: which nodes exist, and what hangs off what.
    private func structureKey(of document: Document) -> String {
        document.nodes
            .map { "\($0.id.uuidString)>\($0.parentID?.uuidString ?? "-")" }
            .sorted()
            .joined(separator: ",")
    }

    // MARK: Canvas gestures (pan · hold to record · double-tap)

    /// What the finger on the bare canvas turned out to be doing.
    private enum CanvasPhase { case idle, pressing, panning, recording }

    private func canvasGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let moved = hypot(value.translation.width, value.translation.height)
                switch phase {
                case .idle:
                    // Every touch starts out ambiguous: it becomes a pan the moment it moves, a
                    // recording if it stays put long enough, and a tap if it does neither.
                    phase = .pressing
                    panOrigin = pan
                    armHold(at: value.startLocation)
                case .pressing:
                    if moved > GraphCanvas.tapSlop {
                        cancelHold()
                        phase = .panning
                    }
                case .panning, .recording:
                    break
                }
                if phase == .panning, let panOrigin {
                    pan = CGPoint(x: panOrigin.x + value.translation.width,
                                  y: panOrigin.y + value.translation.height)
                }
            }
            .onEnded { value in
                cancelHold()
                let moved = hypot(value.translation.width, value.translation.height)
                switch phase {
                case .recording:
                    finishHoldRecording()
                case .idle, .pressing:
                    if moved <= GraphCanvas.tapSlop { registerTap(at: value.startLocation) }
                case .panning:
                    break
                }
                phase = .idle
                panOrigin = nil
            }
    }

    private func zoomGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? ZoomStart(scale: scale, pan: pan, anchor: value.startLocation)
                if zoomStart == nil { zoomStart = start }
                let next = min(max(start.scale * value.magnification,
                                   GraphCanvas.minScale), GraphCanvas.maxScale)
                // Hold the canvas point under the pinch still, so zooming goes where you're looking.
                let focus = CGPoint(x: (start.anchor.x - start.pan.x) / start.scale,
                                    y: (start.anchor.y - start.pan.y) / start.scale)
                pan = CGPoint(x: start.anchor.x - focus.x * next,
                              y: start.anchor.y - focus.y * next)
                scale = next
            }
            .onEnded { _ in zoomStart = nil }
    }

    /// A view point in canvas coordinates — the inverse of the transform `content` applies.
    ///
    /// Held inside the laid-out canvas, so a node made after an hour of panning in one direction
    /// still has a card that's actually drawn. It takes some sixty screenfuls of dragging to reach,
    /// which is why the canvas reads as endless without being so.
    private func canvasPoint(for viewPoint: CGPoint) -> CGPoint {
        let limit = GraphCanvas.center - 200
        return CGPoint(x: min(max((viewPoint.x - pan.x) / scale, -limit), limit),
                       y: min(max((viewPoint.y - pan.y) / scale, -limit), limit))
    }

    // MARK: Hold to record

    private func armHold(at viewPoint: CGPoint) {
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(GraphCanvas.holdDuration * 1_000_000_000))
            guard !Task.isCancelled, phase == .pressing else { return }
            await beginHoldRecording(at: viewPoint)
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
    }

    /// The hold has been held: put a node under the finger and start capturing into it.
    @MainActor
    private func beginHoldRecording(at viewPoint: CGPoint) async {
        guard await recorder.requestPermission() else {
            model.setupError = "Microphone permission is required to record."
            return
        }
        // The permission prompt only ever appears once, but the finger may well have lifted while
        // it was up — there's nothing to record into then.
        guard phase == .pressing else { return }
        finishEditing()
        menuNodeID = nil

        let spot = canvasPoint(for: viewPoint)
        let node = GraphNode(position: GraphPoint(x: spot.x, y: spot.y))
        do {
            try recorder.start(to: model.documents.newAudioURL().url)
        } catch {
            model.setupError = error.localizedDescription
            return
        }
        model.documents.addNode(node, to: documentID)
        layout.hold(node.id)          // stay under the finger for as long as it's down
        recordingNodeID = node.id
        phase = .recording
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// The finger lifted: stop, file the clip against the node it was spoken into, and transcribe.
    private func finishHoldRecording() {
        guard let nodeID = recordingNodeID else { return }
        recordingNodeID = nil
        layout.hold(nil)
        guard let result = recorder.stop() else {
            model.documents.deleteNode(nodeID, in: documentID)
            return
        }
        // A hold released the instant it's recognised isn't a recording. Drop the clip and the node
        // it made, rather than leaving an empty card behind for every stray press.
        guard result.duration >= GraphCanvas.minimumClip else {
            try? FileManager.default.removeItem(at: result.url)
            model.documents.deleteNode(nodeID, in: documentID)
            return
        }
        model.captureGraphNode(audioURL: result.url, duration: result.duration,
                               nodeID: nodeID, in: documentID)
    }

    /// Taps on bare canvas: the second of a pair makes a node to type into, a lone one puts away
    /// whatever is open. (Detected here rather than with a tap gesture of its own, which would be
    /// one more recogniser competing with the press this canvas already reads four ways.)
    private func registerTap(at viewPoint: CGPoint) {
        let now = Date()
        if let last = lastTap, now.timeIntervalSince(last.at) < GraphCanvas.doubleTapWindow,
           hypot(viewPoint.x - last.point.x, viewPoint.y - last.point.y) < 44 {
            lastTap = nil
            addTypedNode(at: viewPoint)
        } else {
            lastTap = (now, viewPoint)
            finishEditing()
            withAnimation(.snappy(duration: 0.2)) { menuNodeID = nil }
        }
    }

    private func addTypedNode(at viewPoint: CGPoint) {
        let spot = canvasPoint(for: viewPoint)
        let node = GraphNode(position: GraphPoint(x: spot.x, y: spot.y))
        model.documents.addNode(node, to: documentID)
        startEditing(node)
    }

    // MARK: Dragging a node (and its branch)

    private func nodeDrag(_ node: GraphNode, in document: Document) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if draggingNodeID != node.id {
                    draggingNodeID = node.id
                    menuNodeID = nil
                    finishEditing()
                    layout.beginDrag(subtree: document.subtree(of: node.id))
                }
                // Translations are in view points; the canvas is in canvas points.
                layout.drag(by: GraphPoint(x: value.translation.width / scale,
                                           y: value.translation.height / scale))
                dropTargetID = dropTarget(for: node, in: document)
            }
            .onEnded { _ in
                let target = dropTargetID
                dropTargetID = nil
                draggingNodeID = nil
                layout.endDrag()
                if let target,
                   model.documents.reparentNode(node.id, to: target, in: documentID) {
                    let name = document.node(with: target)?.trimmedText ?? ""
                    wwLog("Hung a graph branch under “\(name.isEmpty ? "a node" : name)”", .general)
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                }
                layout.commit()
            }
    }

    /// The node a drop would land on: whichever card the dragged node's centre is over, ignoring
    /// the branch being dragged (a node can't hang off itself, or off its own child).
    private func dropTarget(for node: GraphNode, in document: Document) -> UUID? {
        let center = point(of: node.id, in: document)
        let excluded = Set(document.subtree(of: node.id))
        return document.nodes.first(where: { other in
            guard !excluded.contains(other.id) else { return false }
            return rect(of: other, in: document).contains(center)
        })?.id
    }

    private func rect(of node: GraphNode, in document: Document) -> CGRect {
        let center = point(of: node.id, in: document)
        let size = nodeSizes[node.id] ?? CGSize(width: GraphCanvas.nodeWidth, height: 56)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Adding nodes from the "+" buttons

    /// The store places a child relative to its parent's *stored* position; the canvas is showing
    /// the live one, which can be a beat ahead of it while the graph is still moving. Both of these
    /// re-place the new node against what's actually on screen, before the layout adopts it, so it
    /// appears where the "+" was rather than where the last save left things.
    private func addChild(to parent: GraphNode) {
        guard let node = model.documents.addChildNode(to: parent.id, in: documentID) else { return }
        let live = layout.points[parent.id] ?? parent.position
        model.documents.moveNodes(
            [node.id: GraphPoint(x: live.x + (node.position.x - parent.position.x),
                                 y: live.y + (node.position.y - parent.position.y))],
            in: documentID)
        startEditing(node)
    }

    private func insertNode(on edge: GraphEdgeLine) {
        guard let node = model.documents.insertNode(between: edge.parentID, and: edge.id,
                                                    in: documentID) else { return }
        model.documents.moveNodes([node.id: GraphPoint(x: edge.midpoint.x, y: edge.midpoint.y)],
                                  in: documentID)
        startEditing(node)
    }

    // MARK: Editing a node in place

    private func startEditing(_ node: GraphNode) {
        if editingNodeID != nil { finishEditing() }
        menuNodeID = nil
        let text = node.trimmedText
        editingText = text
        editingSelection = NSRange(location: (text as NSString).length, length: 0)
        // Hold it still while it's open: a card that drifts out from under the keyboard mid-sentence
        // is its own kind of infuriating.
        layout.hold(node.id)
        withAnimation(.snappy(duration: 0.22)) { editingNodeID = node.id }
    }

    /// Done: write the buffer back. A node left with nothing in it — typed into and abandoned — is
    /// removed rather than left on the canvas as a blank card; one that's waiting on a recording, or
    /// holding a branch up, stays.
    private func finishEditing() {
        guard let id = editingNodeID else { return }
        editingNodeID = nil
        layout.hold(nil)
        model.documents.setNodeText(id, in: documentID, to: editingText)
        guard let document, let node = document.node(with: id) else { return }
        if !node.hasText, node.recordingID == nil, document.children(of: id).isEmpty {
            model.documents.deleteNode(id, in: documentID)
        }
    }

    /// "Revise" from inside the editor: keep what's typed, then record a clip that replaces it.
    private func reviseEditingNode() {
        guard let id = editingNodeID else { return }
        editingNodeID = nil
        layout.hold(nil)
        model.documents.setNodeText(id, in: documentID, to: editingText)
        reviseTask = ReviseTask(nodeID: id)
    }

    /// "Transform" from inside the editor: flush what's on screen, then pick a preset to run on it.
    private func transformEditingNode() {
        guard let id = editingNodeID else { return }
        editingNodeID = nil
        layout.hold(nil)
        model.documents.setNodeText(id, in: documentID, to: editingText)
        transformTargetID = id
    }

    private func runTransform(_ preset: PromptPreset, nodeID: UUID) {
        transformingNodeIDs.insert(nodeID)
        Task {
            await model.transformGraphNode(preset, nodeID: nodeID, in: documentID)
            transformingNodeIDs.remove(nodeID)
        }
    }

    // MARK: The long-press dropdown

    private func openMenu(for node: GraphNode) {
        finishEditing()
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        withAnimation(.snappy(duration: 0.2)) { menuNodeID = node.id }
    }

    /// The actions a paragraph gets from a swipe, as a list under the node they apply to — there's
    /// no row to swipe on a canvas, so the long press opens them here instead.
    private func menuItems(for node: GraphNode) -> [NodeMenuItem] {
        [
            NodeMenuItem(title: "Edit", icon: "pencil") { startEditing(node) },
            NodeMenuItem(title: "Add Child", icon: "plus") { addChild(to: node) },
            NodeMenuItem(title: "Revise", icon: "mic.fill") {
                menuNodeID = nil
                reviseTask = ReviseTask(nodeID: node.id)
            },
            NodeMenuItem(title: "Transform", icon: "wand.and.stars", enabled: model.modelReady) {
                menuNodeID = nil
                transformTargetID = node.id
            },
            NodeMenuItem(title: "Delete", icon: "trash", isDestructive: true) {
                menuNodeID = nil
                model.documents.deleteNode(node.id, in: documentID)
            }
        ]
    }

    @ViewBuilder
    private func menuOverlay(for document: Document, in size: CGSize) -> some View {
        if let id = menuNodeID, let node = document.node(with: id) {
            let items = menuItems(for: node)
            let height = CGFloat(items.count) * 44 + 8
            let origin = menuOrigin(for: node, in: document, size: size, height: height)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { menuNodeID = nil } }
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { item.action() }
                        } label: {
                            Label(item.title, systemImage: item.icon)
                                .font(.callout)
                                .foregroundStyle(item.isDestructive ? WW.ember : WW.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.enabled)
                        .opacity(item.enabled ? 1 : 0.35)
                        if item.id != items.last?.id { WWHairline().padding(.leading, 16) }
                    }
                }
                .padding(.vertical, 4)
                .frame(width: GraphCanvas.menuWidth)
                .background(WW.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(WW.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
                .offset(x: origin.x, y: origin.y)
            }
            .transition(.opacity)
        }
    }

    /// Under the node it belongs to, nudged back onto the screen when that would hang it off an edge.
    private func menuOrigin(for node: GraphNode, in document: Document,
                            size: CGSize, height: CGFloat) -> CGPoint {
        let center = point(of: node.id, in: document)
        let view = CGPoint(x: center.x * scale + pan.x, y: center.y * scale + pan.y)
        let cardHeight = (nodeSizes[node.id]?.height ?? 56) * scale
        let x = min(max(12, view.x - GraphCanvas.menuWidth / 2), max(12, size.width - GraphCanvas.menuWidth - 12))
        let y = min(max(12, view.y + cardHeight / 2 + 10), max(12, size.height - height - 12))
        return CGPoint(x: x, y: y)
    }

    // MARK: Placing the canvas

    /// Open onto the graph rather than onto wherever the origin happens to be: the first time the
    /// canvas is measured, centre what's already there.
    private func placeCanvas(in size: CGSize, document: Document) {
        guard !didPlaceCanvas, size.width > 0 else { return }
        didPlaceCanvas = true
        pan = centeringPan(for: document, in: size)
    }

    private func centeringPan(for document: Document, in size: CGSize) -> CGPoint {
        let xs = document.nodes.map(\.position.x)
        let ys = document.nodes.map(\.position.y)
        let focus: CGPoint
        if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() {
            focus = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        } else {
            focus = .zero
        }
        return CGPoint(x: size.width / 2 - focus.x * scale, y: size.height / 2 - focus.y * scale)
    }

    private func recenter() {
        guard let document, canvasSize.width > 0 else { return }
        withAnimation(.snappy(duration: 0.3)) {
            scale = 1
            pan = centeringPan(for: document, in: canvasSize)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(for document: Document?) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                renameText = document?.title ?? ""
                showingRename = true
            } label: {
                Text(document?.title ?? "Graph")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(WW.ink)
                    .lineLimit(1)
            }
        }
        if let document {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { copyOutline(document) } label: {
                        Label("Copy Outline", systemImage: "doc.on.doc")
                    }
                    Button {
                        shareItem = ShareItem(text: MarkdownBackup.markdown(for: document))
                    } label: {
                        Label("Share Outline", systemImage: "square.and.arrow.up")
                    }
                    Button { shareDocumentFile(document) } label: {
                        Label("Share as Woods Whisper File", systemImage: "arrow.up.doc")
                    }
                    Divider()
                    Button { recenter() } label: {
                        Label("Center Graph", systemImage: "scope")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    /// The graph as a Markdown outline — nodes as bullets, indented by depth. It's what a graph
    /// copies, shares and backs up as (see `Document.outline`).
    private func copyOutline(_ document: Document) {
        #if canImport(UIKit)
        UIPasteboard.general.string = MarkdownBackup.markdown(for: document)
        #endif
        wwLog("Copied the outline of “\(document.title)” to clipboard", .general)
    }

    private func shareDocumentFile(_ document: Document) {
        if let url = model.exportDocumentFile(document.id) {
            documentFileShare = DocumentFileShareItem(url: url)
        }
    }

    // MARK: Small types

    /// A pinch in progress, as it stood when it began — the fixed point the zoom is worked out from.
    private struct ZoomStart {
        let scale: CGFloat
        let pan: CGPoint
        let anchor: CGPoint
    }

    /// Drives the `RecordingSheet` that records a node's replacement ("Revise").
    private struct ReviseTask: Identifiable {
        let nodeID: UUID
        var id: UUID { nodeID }
    }

    /// One row of the long-press dropdown.
    private struct NodeMenuItem: Identifiable {
        let title: String
        let icon: String
        var isDestructive = false
        var enabled = true
        let action: () -> Void

        var id: String { title }

        init(title: String, icon: String, isDestructive: Bool = false, enabled: Bool = true,
             action: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.isDestructive = isDestructive
            self.enabled = enabled
            self.action = action
        }
    }
}

// MARK: - Canvas constants

/// The handful of numbers the canvas is built from, in one place.
enum GraphCanvas {
    /// How much canvas is laid out at once. The user never meets an edge — panning moves the
    /// viewport, not the content — and this is simply big enough (±12,000 points, some 60 screens
    /// in every direction) that laying it out as one container costs nothing.
    static let extent: CGFloat = 24_000
    static var center: CGFloat { extent / 2 }

    static let nodeWidth: CGFloat = 180
    /// A node that's open for editing, which has an action row to fit as well as its text.
    static let editingNodeWidth: CGFloat = 240
    static let menuWidth: CGFloat = 210
    static let gridSpacing: CGFloat = 44

    static let minScale: CGFloat = 0.35
    static let maxScale: CGFloat = 2.5

    /// How long a press has to hold still before it becomes a recording.
    static let holdDuration: TimeInterval = 0.4
    /// A clip shorter than this was a stray press, not something said.
    static let minimumClip: TimeInterval = 0.3
    /// How far a touch may drift and still count as a press rather than a pan.
    static let tapSlop: CGFloat = 12
    static let doubleTapWindow: TimeInterval = 0.35
}

// MARK: - Edges

/// One parent→child line, in canvas coordinates. Named by the child, since that's the node the edge
/// belongs to: insert a node "on" this edge and the child is what it adopts.
struct GraphEdgeLine: Identifiable {
    let id: UUID
    let parentID: UUID
    let from: CGPoint
    let to: CGPoint

    var midpoint: CGPoint { CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2) }
}

/// Every edge as one stroked path — cheaper than a view per line, and it can't get out of step with
/// the nodes because both read the same live positions.
private struct GraphEdgeShape: Shape {
    let edges: [GraphEdgeLine]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            path.move(to: CGPoint(x: edge.from.x + GraphCanvas.center,
                                  y: edge.from.y + GraphCanvas.center))
            path.addLine(to: CGPoint(x: edge.to.x + GraphCanvas.center,
                                     y: edge.to.y + GraphCanvas.center))
        }
        return path
    }
}

// MARK: - Grid

/// The very light grid under the graph: lines every `gridSpacing` canvas points, drawn in view
/// space so panning slides them and zooming spaces them out. Zoom far enough out and the spacing
/// doubles rather than closing into a wash of ink.
private struct GraphGrid: View {
    let pan: CGPoint
    let scale: CGFloat

    var body: some View {
        Canvas { context, size in
            var spacing = max(GraphCanvas.gridSpacing * scale, 8)
            while spacing < 18 { spacing *= 2 }

            var path = Path()
            var x = pan.x.truncatingRemainder(dividingBy: spacing)
            if x > 0 { x -= spacing }
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y = pan.y.truncatingRemainder(dividingBy: spacing)
            if y > 0 { y -= spacing }
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(WW.hairline.opacity(0.65)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The "+" button

/// The small "+" that hangs off a node's right edge (add a child) and sits midway along each line
/// (insert a node between the two it joins). One control, two places, so both read as the same
/// "put something here".
private struct GraphPlusButton: View {
    var diameter: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WW.moss)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(WW.surface))
                .overlay(Circle().stroke(WW.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Layout engine

/// Runs `GraphLayout` for an open canvas: holds the live positions, steps the simulation until the
/// graph settles, and writes the settled positions back through `onSettle`.
///
/// Positions are deliberately *not* stored on every frame — a relaxing graph would otherwise rewrite
/// the document (and its Markdown backup) sixty times a second. They're written when the graph comes
/// to rest, when a drag ends, and when the canvas closes.
@MainActor
final class GraphLayoutEngine: ObservableObject {
    /// Where every node is right now. The canvas reads this rather than the stored positions.
    @Published private(set) var points: [UUID: GraphPoint] = [:]

    /// Called with the positions worth keeping, once the graph has stopped moving.
    var onSettle: (([UUID: GraphPoint]) -> Void)?

    private var bodies: [GraphLayout.Body] = []
    private var pinned: Set<UUID> = []
    private var held: UUID?
    private var dragOrigins: [UUID: GraphPoint] = [:]
    private var timer: Timer?
    private var frames = 0

    private let frameInterval: TimeInterval = 1.0 / 30
    private let settledDistance: Double = 0.2
    /// A graph that won't settle stops after this many steps rather than spinning forever.
    private let maxFrames = 600

    /// Adopt the document's nodes: new ones arrive at their stored position, familiar ones keep the
    /// position the simulation has them at. Any change to the shape of the graph starts it moving.
    func sync(with document: Document) {
        var next: [GraphLayout.Body] = []
        var changed = bodies.count != document.nodes.count
        for node in document.nodes {
            let existing = bodies.first { $0.id == node.id }
            if existing == nil || existing?.parentID != node.parentID { changed = true }
            next.append(GraphLayout.Body(
                id: node.id,
                parentID: node.parentID,
                position: existing?.position ?? node.position,
                // Only roots are anchored, and only to where they were put — a child hangs wherever
                // its springs leave it.
                home: node.parentID == nil ? (existing?.home ?? node.position) : nil,
                isPinned: isFrozen(node.id)))
        }
        bodies = next
        publish()
        if changed { start() }
    }

    /// Hold one node exactly where it is — the one being edited, or the one being recorded into. A
    /// card shouldn't wander out from under the keyboard while you're typing into it, or away from
    /// the finger that's holding it down. Pass nil to let it go.
    func hold(_ id: UUID?) {
        guard held != id else { return }
        held = id
        for index in bodies.indices { bodies[index].isPinned = isFrozen(bodies[index].id) }
        start()
    }

    /// Nodes the simulation may not move: the branch under a drag, and the held node.
    private func isFrozen(_ id: UUID) -> Bool { pinned.contains(id) || held == id }

    // MARK: Dragging

    /// Pin a branch under the user's finger. It stops being moved by the simulation, but keeps
    /// pushing everything else around — so the rest of the graph makes room as it's dragged through.
    func beginDrag(subtree ids: [UUID]) {
        pinned = Set(ids)
        dragOrigins = [:]
        for index in bodies.indices {
            bodies[index].isPinned = isFrozen(bodies[index].id)
            guard pinned.contains(bodies[index].id) else { continue }
            dragOrigins[bodies[index].id] = bodies[index].position
        }
        start()
    }

    /// Move the pinned branch to `delta` from where it was when the drag began. (Cumulative, not
    /// incremental: it's the gesture's own translation, so nothing drifts.)
    func drag(by delta: GraphPoint) {
        for index in bodies.indices {
            guard let origin = dragOrigins[bodies[index].id] else { continue }
            bodies[index].position = GraphPoint(x: origin.x + delta.x, y: origin.y + delta.y)
        }
        publish()
    }

    func endDrag() {
        for index in bodies.indices where pinned.contains(bodies[index].id) {
            // A root dropped somewhere new wants to stay there, so that's its home from now on.
            if bodies[index].parentID == nil { bodies[index].home = bodies[index].position }
        }
        pinned = []
        for index in bodies.indices { bodies[index].isPinned = isFrozen(bodies[index].id) }
        dragOrigins = [:]
        publish()
        start()
    }

    // MARK: The loop

    func start() {
        frames = 0
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stop stepping, and write the positions back.
    func stop() {
        timer?.invalidate()
        timer = nil
        commit()
    }

    func commit() {
        guard !points.isEmpty else { return }
        onSettle?(points)
    }

    private func tick() {
        let next = GraphLayout.step(bodies)
        let moved = GraphLayout.maxDisplacement(from: bodies, to: next)
        bodies = next
        publish()
        frames += 1
        // A drag keeps it running however still the graph looks: the branch under the finger is
        // pinned, so "nothing moved" says nothing about whether the gesture is over.
        if (moved < settledDistance && pinned.isEmpty) || frames >= maxFrames { stop() }
    }

    private func publish() {
        var next: [UUID: GraphPoint] = [:]
        next.reserveCapacity(bodies.count)
        for body in bodies { next[body.id] = body.position }
        points = next
    }
}
