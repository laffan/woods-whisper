import Foundation

/// A point on a graph document's canvas, in canvas points. Plain `Double`s rather than `CGPoint`
/// so the model stays Foundation-only (and encodes as two obvious numbers in the JSON on disk).
///
/// The canvas has no edges: coordinates run in every direction from the origin and the view pans
/// and zooms over them, so "more space" is always just a drag away.
public struct GraphPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    public static let zero = GraphPoint(x: 0, y: 0)
}

/// One node of a **graph document** — a mind map rather than a body of prose.
///
/// A node is the graph's answer to a document's `Paragraph`: a small block of editable text, laid
/// out on the canvas, optionally with the clip it was spoken into behind it (`recordingID`, which
/// points at one of the document's own `recordings`). Its `text` is the node's own copy — a
/// recording's transcript is *copied* in the first time it arrives, so editing, transforming, or
/// re-recording a node never has to reach back into the clip.
///
/// Structure is a plain parent pointer: `parentID` nil means a root. Dragging a node moves
/// everything hanging off it, dropping it on another node re-parents the whole branch, and the
/// Markdown export walks the same pointers to produce an indented outline.
public struct GraphNode: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID

    /// The node's words. Empty until the clip behind it has been transcribed — or until it's typed,
    /// for a node created by double-tapping the canvas.
    public var text: String

    /// The node this one hangs off; nil for a root.
    public var parentID: UUID?

    /// Where the node sits on the canvas: exactly where it was put, and there until it's dragged
    /// somewhere else. Written back when a drag ends rather than on every frame of one.
    public var position: GraphPoint

    /// The recording this node was spoken into, if any. Nil for a node typed straight onto the
    /// canvas; the clip itself lives in the document's `recordings` like any other.
    public var recordingID: UUID?

    /// The ink this card is drawn in — one of `GraphPalette.colorIDs`, or nil for the canvas's own
    /// plain card. It colours the border and tints the background; it says nothing about structure,
    /// exactly like the ring round a group.
    public var colorID: String?

    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String = "",
        parentID: UUID? = nil,
        position: GraphPoint = .zero,
        recordingID: UUID? = nil,
        colorID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.parentID = parentID
        self.position = position
        self.recordingID = recordingID
        self.colorID = colorID
        self.createdAt = createdAt
    }

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether this node has anything to say yet. An empty node is a real state — it exists from the
    /// moment a hold starts recording, and only fills in once the words come back.
    public var hasText: Bool { !trimmedText.isEmpty }

    /// The heading this node's text opens with, if it opens with one — `# ` or `## `.
    public var heading: GraphHeading? { GraphHeading.parse(text) }

    /// What the card shows: the node's words with a heading marker taken off, since the `#` is how
    /// you *said* "make this a heading" and the size on screen is what it turned into. The stored
    /// text keeps the marker, so editing the node shows it again — and so does the outline this
    /// graph exports, where a `#` is a heading in its own right rather than a stray character.
    public var displayText: String { heading?.text ?? trimmedText }
}

/// A node and how deep it hangs in the graph — one line of the node list, and the shape the
/// outline is built from.
public struct GraphNodeEntry: Identifiable, Hashable, Sendable {
    public let node: GraphNode
    public let depth: Int

    public var id: UUID { node.id }

    public init(node: GraphNode, depth: Int) {
        self.node = node
        self.depth = depth
    }
}

// MARK: - Reading a graph

/// The read side of a graph document: structure queries, the visual ordering the outline follows,
/// and the Markdown export. Pure and dependency-free, so it's all unit-testable — `DocumentStore`
/// holds the matching mutations.
extension Document {

    public var isGraph: Bool { kind == .graph }

    public func node(with id: UUID) -> GraphNode? {
        nodes.first { $0.id == id }
    }

    /// The nodes with no parent, in the order the canvas reads.
    public var rootNodes: [GraphNode] { orderedNodes(under: nil) }

    /// The nodes hanging directly off `parentID`, in the order the canvas reads.
    public func children(of parentID: UUID) -> [GraphNode] { orderedNodes(under: parentID) }

    /// Visual order — down the canvas first, then across it — so an exported outline is in the same
    /// order as what's on screen rather than in the order the nodes happened to be created.
    private func orderedNodes(under parentID: UUID?) -> [GraphNode] {
        nodes
            .filter { $0.parentID == parentID }
            .sorted { lhs, rhs in
                if lhs.position.y != rhs.position.y { return lhs.position.y < rhs.position.y }
                if lhs.position.x != rhs.position.x { return lhs.position.x < rhs.position.x }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// `id` and every node hanging off it — the branch a drag carries with it and a delete takes
    /// into account. Cycle-safe: a node is visited once however tangled the parent pointers are.
    public func subtree(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var seen: Set<UUID> = []
        var pending = [id]
        while let next = pending.popLast() {
            guard seen.insert(next).inserted else { continue }
            result.append(next)
            pending.append(contentsOf: nodes.filter { $0.parentID == next }.map(\.id))
        }
        return result
    }

    /// Whether `id` sits somewhere above `other` in the tree. This is the guard on re-parenting:
    /// dropping a node onto one of its own descendants would leave a cycle no walk could escape.
    public func isAncestor(_ id: UUID, of other: UUID) -> Bool {
        var current = node(with: other)?.parentID
        var steps = 0
        while let parent = current, steps <= nodes.count {
            if parent == id { return true }
            current = node(with: parent)?.parentID
            steps += 1
        }
        return false
    }

    /// The graph as a Markdown outline: one bullet per node, indented two spaces per level, in the
    /// order the canvas reads. This is what a graph document exports, copies, shares and backs up
    /// as — a mind map flattened into the shape it already has.
    ///
    /// A node with no words yet — a clip still transcribing, a node you haven't typed into — isn't
    /// given a bullet of its own, and anything hanging off it moves up to take its place, so the
    /// outline never carries an empty line with children dangling under it.
    public var outline: String {
        var lines: [String] = []
        var seen: Set<UUID> = []

        func walk(_ branch: [GraphNode], depth: Int) {
            for node in branch {
                guard seen.insert(node.id).inserted else { continue }   // cycle guard
                let kids = children(of: node.id)
                if node.hasText {
                    lines.append(contentsOf: Self.bullet(node.trimmedText, depth: depth))
                    walk(kids, depth: depth + 1)
                } else {
                    walk(kids, depth: depth)
                }
            }
        }

        walk(rootNodes, depth: 0)
        return lines.joined(separator: "\n")
    }

    /// One node as outline lines: its first line as the bullet, any further lines indented to sit
    /// under it (so a multi-sentence transcript stays one bullet rather than becoming several).
    private static func bullet(_ text: String, depth: Int) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        let parts = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return [] }
        return [indent + "- " + first] + parts.dropFirst().map { indent + "  " + $0 }
    }

    /// Every node in the order the outline reads, each with how deep it sits — what the canvas's
    /// "List Nodes" shows, so the list is in the same order as the export and you can go from a
    /// line of it straight to that node on the canvas.
    ///
    /// Unlike `outline` this keeps the nodes with nothing in them yet: a clip still transcribing is
    /// exactly the sort of thing you'd want to find your way back to.
    public var nodeEntries: [GraphNodeEntry] {
        var entries: [GraphNodeEntry] = []
        var seen: Set<UUID> = []

        func walk(_ branch: [GraphNode], depth: Int) {
            for node in branch {
                guard seen.insert(node.id).inserted else { continue }   // cycle guard
                entries.append(GraphNodeEntry(node: node, depth: depth))
                walk(children(of: node.id), depth: depth + 1)
            }
        }

        walk(rootNodes, depth: 0)
        return entries
    }

    /// Somewhere to put a node that arrived without a place of its own — a Watch clip filed into a
    /// graph, or a recording moved in from the Inbox. Below whatever is already there, so nothing
    /// lands on top of an existing node.
    public func nextRootPosition(spacing: Double = 150) -> GraphPoint {
        guard let lowest = nodes.map(\.position.y).max() else { return .zero }
        return GraphPoint(x: 0, y: lowest + spacing)
    }
}
