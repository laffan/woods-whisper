import Foundation

/// A flowchart copied out of a Hush notebook, read as graph nodes — what lets **Paste Nodes**,
/// **Paste as Child** and ⌘V take a copy made in Hush.
///
/// Hush puts its copies on the pasteboard as a `canvas-clipboard@1` envelope: the shapes picked
/// out, the flowchart's arrows between them, and (from Hush's own copies) each shape's box on its
/// canvas. On the Mac and the iPad it goes under its own type as well as as text, which is what
/// lets a menu here ask whether there's a flowchart to paste without reading — and so without the
/// system's "Allow Paste" prompt.
///
/// What crosses, and what doesn't:
/// • **Text shapes become cards.** Everything else on a notebook canvas — ink, images, the boxes
///   things are dragged into — has no card to become, and stays behind.
/// • **An arrow is a parent.** Hush draws an arrow from parent to child and lets a shape have one
///   parent, which is a graph's own rule; an arrow to or from something that didn't come along is
///   dropped, as a link out of a copy is here.
/// • **Where things sit is kept, by their middles.** A card's position is its centre and a
///   Hush shape's is its top-left corner, so each card goes where the middle of its shape was —
///   which is what keeps the copy in the shape it was drawn in.
/// • **A shape wider than a card makes a wider card**, so a paragraph doesn't arrive as a column.
/// • **A Hush group becomes a ring** round whichever of its members came along.
public enum HushCanvasClipboard {
    /// The type Hush puts its copies under on Apple platforms, beside the same JSON as text.
    public static let typeIdentifier = "com.hushwriter.canvas-clipboard"
    /// The envelope's own name for itself — shared with Steiner, which Hush trades copies with.
    public static let schema = "canvas-clipboard@1"

    /// The nodes in a Hush copy — nil for anything that isn't one, or one with no text in it.
    public static func graph(from data: Data) -> GraphClipboard? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schema == schema else { return nil }
        return graph(from: envelope)
    }

    private static func graph(from envelope: Envelope) -> GraphClipboard? {
        let made = Date()
        var ids: [String: UUID] = [:]
        var nodes: [GraphNode] = []
        var groupOf: [String: String] = [:]
        for shape in envelope.shapes where shape.type == "text" && ids[shape.id] == nil {
            guard let text = shape.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let box = envelope.bounds?[shape.id] ?? estimatedBox(of: shape) else { continue }
            let id = UUID()
            ids[shape.id] = id
            if let group = shape.groupId { groupOf[shape.id] = group }
            let width = box.maxX - box.minX
            nodes.append(GraphNode(id: id,
                                   text: text,
                                   position: GraphPoint(x: (box.minX + box.maxX) / 2,
                                                        y: (box.minY + box.maxY) / 2),
                                   width: width > standardCardWidth
                                       ? min(width, maximumCardWidth) : nil,
                                   createdAt: made))
        }
        guard !nodes.isEmpty else { return nil }

        // One parent each — the first arrow into a shape — and only from a shape that came along.
        var parents: [UUID: UUID] = [:]
        for edge in envelope.flowEdges ?? [] {
            guard let child = ids[edge.to], let parent = ids[edge.from], child != parent,
                  parents[child] == nil else { continue }
            parents[child] = parent
        }
        nodes = nodes.map { node in
            var linked = node
            linked.parentID = parents[node.id]
            return linked
        }

        var members: [String: [UUID]] = [:]
        var order: [String] = []
        for shape in envelope.shapes {
            guard let group = groupOf[shape.id], let id = ids[shape.id] else { continue }
            if members[group] == nil { order.append(group) }
            if members[group]?.contains(id) != true { members[group, default: []].append(id) }
        }
        let groups = order.compactMap { key -> GraphGroup? in
            guard let ids = members[key], ids.count >= GraphGroup.minimumMembers else { return nil }
            return GraphGroup(memberIDs: ids, createdAt: made)
        }
        return GraphClipboard(nodes: nodes, groups: groups)
    }

    /// A card nobody has resized (`DocumentStore`'s card width), and the widest one can be
    /// dragged out to on the canvas.
    private static let standardCardWidth: Double = 180
    private static let maximumCardWidth: Double = 640

    /// A shape's box when the copy didn't say — Steiner's copies, and Hush's from before it did.
    /// Rough on purpose: the words at about half an em a character, wrapped at the shape's own
    /// width, a line and a third apart (Hush's own line height). Near enough to put each card
    /// round where its shape was, which is all a position is for here.
    private static func estimatedBox(of shape: Shape) -> Box? {
        guard let origin = shape.position, let text = shape.text else { return nil }
        let fontSize = shape.fontSize ?? 16
        let charWidth = fontSize * 0.5
        let lines = text.components(separatedBy: .newlines)
        let widest = Double(lines.map(\.count).max() ?? 0) * charWidth
        let wrapAt = shape.width.map { max($0, charWidth) } ?? widest
        let width = max(min(widest, wrapAt), charWidth)
        let rows = lines.reduce(0.0) { sum, line in
            sum + max(1, (Double(line.count) * charWidth / width).rounded(.up))
        }
        return Box(minX: origin.x, minY: origin.y,
                   maxX: origin.x + width, maxY: origin.y + rows * fontSize * 1.3)
    }

    // MARK: The envelope, as far as it's read

    /// Only what a card can use is decoded; anything else in the envelope is passed over, so a
    /// shape this doesn't know (or a field Hush adds later) costs nothing.
    private struct Envelope: Decodable {
        let schema: String
        let shapes: [Shape]
        let flowEdges: [Edge]?
        let bounds: [String: Box]?

        private enum CodingKeys: String, CodingKey { case schema, shapes, flowEdges, bounds }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decode(String.self, forKey: .schema)
            // A shape this can't read is skipped rather than sinking the whole paste.
            shapes = try container.decode([Lenient<Shape>].self, forKey: .shapes).compactMap(\.value)
            flowEdges = (try? container.decodeIfPresent([Lenient<Edge>].self, forKey: .flowEdges))?
                .compactMap(\.value)
            bounds = try? container.decodeIfPresent([String: Box].self, forKey: .bounds)
        }
    }

    private struct Shape: Decodable {
        let id: String
        let type: String
        let text: String?
        let position: GraphPoint?
        let fontSize: Double?
        let width: Double?
        let groupId: String?
    }

    private struct Edge: Decodable {
        let from: String
        let to: String
    }

    private struct Box: Decodable {
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
    }

    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}
