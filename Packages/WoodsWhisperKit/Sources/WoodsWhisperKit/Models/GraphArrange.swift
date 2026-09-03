import Foundation

/// A node's card as the canvas actually drew it: where its centre sits, and how big it came out.
///
/// Alignment needs the *edges* of a card, and only the view knows those — a node's stored position
/// is its centre, and its height depends on how much it ended up saying. So the view measures, this
/// carries the measurement, and `GraphArrange` does the arithmetic somewhere it can be tested.
public struct GraphNodeBox: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let center: GraphPoint
    public let width: Double
    public let height: Double

    public init(id: UUID, center: GraphPoint, width: Double, height: Double) {
        self.id = id
        self.center = center
        self.width = width
        self.height = height
    }

    public var minX: Double { center.x - width / 2 }
    public var maxX: Double { center.x + width / 2 }
    public var minY: Double { center.y - height / 2 }
    public var maxY: Double { center.y + height / 2 }
}

/// Lining a selection up: the four arrangements a set of selected nodes can be put through, each
/// returning the new **centres** of the nodes it actually moves.
///
/// Only the selected nodes move — not the branches hanging off them. Selecting is picking out
/// particular cards, and this tidies exactly those; dragging is still how a branch travels whole.
public enum GraphArrange {

    /// Left edges to the leftmost left edge.
    public static func alignLeft(_ boxes: [GraphNodeBox]) -> [UUID: GraphPoint] {
        guard boxes.count >= minimumToAlign, let edge = boxes.map(\.minX).min() else { return [:] }
        return moves(boxes) { box in GraphPoint(x: edge + box.width / 2, y: box.center.y) }
    }

    /// Right edges to the rightmost right edge — ⌘→, where ⌘← is `alignLeft`. It isn't in the
    /// selection bar (four buttons is already a row) but the keyboard has a side for each.
    public static func alignRight(_ boxes: [GraphNodeBox]) -> [UUID: GraphPoint] {
        guard boxes.count >= minimumToAlign, let edge = boxes.map(\.maxX).max() else { return [:] }
        return moves(boxes) { box in GraphPoint(x: edge - box.width / 2, y: box.center.y) }
    }

    /// Top edges to the topmost top edge.
    public static func alignTop(_ boxes: [GraphNodeBox]) -> [UUID: GraphPoint] {
        guard boxes.count >= minimumToAlign, let edge = boxes.map(\.minY).min() else { return [:] }
        return moves(boxes) { box in GraphPoint(x: box.center.x, y: edge + box.height / 2) }
    }

    /// Even gaps across, between the outermost two — which stay where they are.
    public static func distributeHorizontally(_ boxes: [GraphNodeBox]) -> [UUID: GraphPoint] {
        distribute(boxes, acrossX: true)
    }

    /// Even gaps down the page, between the outermost two — which stay where they are.
    public static func distributeVertically(_ boxes: [GraphNodeBox]) -> [UUID: GraphPoint] {
        distribute(boxes, acrossX: false)
    }

    /// Two cards can be lined up; distributing them would have nothing to say, since the two ends
    /// are exactly what distributing holds still.
    public static let minimumToAlign = 2
    public static let minimumToDistribute = 3

    /// The gaps between cards are evened out, not the distance between their centres: cards differ
    /// in height, and a column spaced by centres leaves the tall ones crowding their neighbours.
    private static func distribute(_ boxes: [GraphNodeBox], acrossX: Bool) -> [UUID: GraphPoint] {
        guard boxes.count >= minimumToDistribute else { return [:] }
        let ordered = boxes.sorted { acrossX ? $0.minX < $1.minX : $0.minY < $1.minY }
        let extent: (GraphNodeBox) -> Double = { acrossX ? $0.width : $0.height }
        guard let leading = ordered.map({ acrossX ? $0.minX : $0.minY }).min(),
              let trailing = ordered.map({ acrossX ? $0.maxX : $0.maxY }).max()
        else { return [:] }

        let occupied = ordered.reduce(0.0) { $0 + extent($1) }
        let gap = (trailing - leading - occupied) / Double(ordered.count - 1)

        var cursor = leading
        var positions: [UUID: GraphPoint] = [:]
        for box in ordered {
            let middle = cursor + extent(box) / 2
            let center = acrossX
                ? GraphPoint(x: middle, y: box.center.y)
                : GraphPoint(x: box.center.x, y: middle)
            if moved(box.center, to: center) { positions[box.id] = center }
            cursor += extent(box) + gap
        }
        return positions
    }

    /// The new centres, leaving out the cards that were already where they belong — a no-op
    /// shouldn't count as an edit, or read as one on the canvas.
    private static func moves(_ boxes: [GraphNodeBox],
                              _ place: (GraphNodeBox) -> GraphPoint) -> [UUID: GraphPoint] {
        var positions: [UUID: GraphPoint] = [:]
        for box in boxes {
            let center = place(box)
            if moved(box.center, to: center) { positions[box.id] = center }
        }
        return positions
    }

    /// Sub-point differences are rounding, not movement.
    private static func moved(_ from: GraphPoint, to: GraphPoint) -> Bool {
        abs(from.x - to.x) > 0.5 || abs(from.y - to.y) > 0.5
    }
}
