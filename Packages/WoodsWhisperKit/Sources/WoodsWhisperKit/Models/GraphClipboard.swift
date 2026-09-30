import Foundation

/// Nodes on their way from one graph to another — what a card's **Copy ▸ Card** and **Branch**, the
/// selection bar's **Copy** and ⌘C put on the pasteboard, and what **Paste Nodes**, a card's
/// **Paste as Child** and ⌘V read back. Into another graph, or somewhere else in the same one.
///
/// The ⌥ drag's rules, because a paste is a copy that's travelled:
/// • **Links inside what was copied survive; a link out of it doesn't.** A branch arrives as that
///   branch, its shape intact, but the node it hung from stayed behind — so whatever was copied
///   without its parent arrives as a root, to be put down somewhere or hung off a card.
/// • **The words travel, the tape doesn't.** A node owns the clip it was spoken into; that clip is
///   one of the *source* document's recordings, and a copy pointing at it would be pointing into a
///   document it isn't in.
/// • **Colour and width travel** — they're how the card is drawn, and a card should arrive looking
///   like the one that was copied. So does a **group** whose members were all copied: its ring is
///   drawn round the pasted cards, with its name and ink.
///
/// Nothing here has been given new ids yet. The ids are the originals', which is what lets one
/// copy be pasted any number of times: each paste (`instantiated`) mints its own.
public struct GraphClipboard: Codable, Hashable, Sendable {
    /// The pasteboard type the nodes travel under. The words go beside them as plain text (`text`),
    /// so anything that isn't a graph canvas — another app, a document's Import from Clipboard —
    /// still gets what the cards say.
    public static let typeIdentifier = "com.woodswhisper.graph-nodes"

    /// The copied nodes, positions and all — a link to a node that wasn't copied already cut.
    public var nodes: [GraphNode]
    /// The rings round copied nodes, where every member was copied.
    public var groups: [GraphGroup]

    public init(nodes: [GraphNode], groups: [GraphGroup] = []) {
        self.nodes = nodes
        self.groups = groups
    }

    /// Copy `ids` out of `document`: the nodes in the order the document keeps them, a parent that
    /// wasn't copied cut off, no recording, and every ring whose members all came along. Nil when
    /// none of `ids` is in the document.
    public init?(copying ids: Set<UUID>, from document: Document) {
        let picked = document.nodes.filter { ids.contains($0.id) }
        guard !picked.isEmpty else { return nil }
        let copied = Set(picked.map(\.id))
        nodes = picked.map { node in
            var copy = node
            if let parent = node.parentID, !copied.contains(parent) { copy.parentID = nil }
            copy.recordingID = nil
            return copy
        }
        groups = document.groups.filter { group in
            group.memberIDs.count >= GraphGroup.minimumMembers && group.members.isSubset(of: copied)
        }
    }

    public var isEmpty: Bool { nodes.isEmpty }

    /// The middle of what was copied, by the nodes' centres: the point a paste puts where it's
    /// asked to, so the copy arrives round that spot rather than hanging off one corner of it.
    public var center: GraphPoint {
        let xs = nodes.map(\.position.x)
        let ys = nodes.map(\.position.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return GraphPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    /// What the copied cards say, for anywhere that takes text. One card is its words as they read
    /// (what a card's **Copy** always handed over); more than one is the outline of them — the same
    /// Markdown a graph exports, so a branch pasted into a note arrives in the shape it had.
    public var text: String {
        if nodes.count == 1, let only = nodes.first { return only.plainText }
        return asDocument.outline
    }

    /// Fresh copies, ready to go into a graph: new ids, the links between them following the new
    /// ids, every position moved by `(dx, dy)`, and a fresh ring for each group that came along.
    /// `map` says which original each copy came from.
    ///
    /// A pasteboard is outside the app's hands, so what's read off one is taken on trust only as
    /// far as it's safe to: a node listed twice is pasted once, and a parent pointer that would
    /// close a loop is cut — a cycle is a graph no outline can walk out of.
    public func instantiated(offsetBy dx: Double, _ dy: Double)
        -> (nodes: [GraphNode], groups: [GraphGroup], map: [UUID: UUID]) {
        var map: [UUID: UUID] = [:]
        var originals: [GraphNode] = []
        for node in nodes where map[node.id] == nil {
            map[node.id] = UUID()
            originals.append(node)
        }
        let parents = acyclicParents(of: originals)
        let copies = originals.compactMap { node -> GraphNode? in
            guard let id = map[node.id] else { return nil }
            return GraphNode(id: id,
                             text: node.text,
                             parentID: parents[node.id].flatMap { map[$0] },
                             position: GraphPoint(x: node.position.x + dx, y: node.position.y + dy),
                             recordingID: nil,
                             colorID: node.colorID,
                             width: node.width,
                             createdAt: node.createdAt)
        }
        let rings = groups.compactMap { group -> GraphGroup? in
            let members = group.memberIDs.compactMap { map[$0] }
            guard members.count >= GraphGroup.minimumMembers else { return nil }
            return GraphGroup(label: group.label, memberIDs: members, colorID: group.colorID)
        }
        return (copies, rings, map)
    }

    /// Each node's parent, where it has one inside the copy and following it doesn't lead back
    /// round to the node itself.
    private func acyclicParents(of nodes: [GraphNode]) -> [UUID: UUID] {
        var parents: [UUID: UUID] = [:]
        let present = Set(nodes.map(\.id))
        for node in nodes {
            if let parent = node.parentID, present.contains(parent) { parents[node.id] = parent }
        }
        // Walk up from each node; one that meets itself on the way is cut loose, which breaks the
        // loop for everyone else on it.
        for node in nodes {
            var current = parents[node.id]
            var steps = 0
            while let next = current, steps <= nodes.count {
                if next == node.id {
                    parents[node.id] = nil
                    break
                }
                current = parents[next]
                steps += 1
            }
        }
        return parents
    }

    /// The copy as a graph of its own, for the one question `Document` already knows how to
    /// answer: what the outline says.
    private var asDocument: Document {
        Document(title: "", kind: .graph, nodes: nodes, groups: groups)
    }

    // MARK: On the pasteboard

    /// What goes on the pasteboard under `typeIdentifier`.
    public func encoded() -> Data? {
        try? JSONEncoder.iso.encode(self)
    }

    /// What came off it — nil for anything that isn't a copy of nodes.
    public init?(data: Data) {
        guard let decoded = try? JSONDecoder.iso.decode(GraphClipboard.self, from: data) else {
            return nil
        }
        self = decoded
    }
}
