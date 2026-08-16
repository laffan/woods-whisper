import Foundation

/// The force-directed relaxation behind a graph document's layout.
///
/// Three forces, applied one step at a time: every node pushes every other node away (so nothing
/// piles up), every parent–child edge pulls like a spring towards its ideal length (so a branch
/// hangs together), and every *root* is held loosely to a home position — the spot it was placed
/// or last dragged to — so the graph as a whole stays where the user put it instead of drifting.
///
/// Pure and Foundation-only: bodies in, bodies out. The view runs it a step at a time and stops as
/// soon as the graph has settled; the tests run it to convergence in a loop.
public enum GraphLayout {

    /// One node as the simulation sees it — position plus the two things that pin it down.
    public struct Body: Identifiable, Hashable, Sendable {
        public var id: UUID
        public var parentID: UUID?
        public var position: GraphPoint
        /// Where a root wants to be. Nil for a child, which is free to hang wherever the springs
        /// leave it, and nil for a root that has never been placed deliberately.
        public var home: GraphPoint?
        /// Held exactly where it is: the node under the user's finger, and everything hanging off
        /// it, while a drag is in progress.
        public var isPinned: Bool

        public init(id: UUID, parentID: UUID? = nil, position: GraphPoint,
                    home: GraphPoint? = nil, isPinned: Bool = false) {
            self.id = id
            self.parentID = parentID
            self.position = position
            self.home = home
            self.isPinned = isPinned
        }
    }

    /// The constants that shape the layout. The defaults are tuned for the node cards the canvas
    /// draws (about 180 points wide): a parent and child settle roughly a card and a half apart,
    /// and unrelated nodes keep their distance without shoving each other off the screen.
    public struct Settings: Sendable {
        /// How far apart a spring would like to hold a parent and its child.
        public var idealEdgeLength: Double
        /// Spring stiffness along parent–child edges.
        public var spring: Double
        /// How hard nodes push each other apart (an inverse-square term, so it dies off quickly).
        public var repulsion: Double
        /// How firmly a root is held to its home position.
        public var rootAnchor: Double
        /// The furthest any node may travel in a single step — the thing that keeps a graph that
        /// starts stacked in one spot from exploding across the canvas.
        public var maxStep: Double

        public init(idealEdgeLength: Double = 150,
                    spring: Double = 0.08,
                    repulsion: Double = 90_000,
                    rootAnchor: Double = 0.02,
                    maxStep: Double = 24) {
            self.idealEdgeLength = idealEdgeLength
            self.spring = spring
            self.repulsion = repulsion
            self.rootAnchor = rootAnchor
            self.maxStep = maxStep
        }
    }

    /// One relaxation step. Pinned bodies contribute forces but never move.
    public static func step(_ bodies: [Body], settings: Settings = Settings()) -> [Body] {
        guard bodies.count > 1 || bodies.first?.home != nil else { return bodies }

        let count = bodies.count
        var fx = [Double](repeating: 0, count: count)
        var fy = [Double](repeating: 0, count: count)

        // Everything pushes everything else away.
        for i in 0..<count {
            for j in (i + 1)..<count {
                var dx = bodies[i].position.x - bodies[j].position.x
                var dy = bodies[i].position.y - bodies[j].position.y
                var distanceSquared = dx * dx + dy * dy
                // Two nodes exactly on top of each other have no direction to separate along, so
                // one is invented from their indices — deterministic, so a layout never depends on
                // a random seed.
                if distanceSquared < 0.01 {
                    dx = Double(i - j)
                    dy = Double((i + j) % 3) - 1
                    distanceSquared = dx * dx + dy * dy
                }
                let distance = distanceSquared.squareRoot()
                let force = settings.repulsion / distanceSquared
                fx[i] += dx / distance * force
                fy[i] += dy / distance * force
                fx[j] -= dx / distance * force
                fy[j] -= dy / distance * force
            }
        }

        // Parent–child edges pull towards the ideal length.
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(count)
        for (index, body) in bodies.enumerated() { indexByID[body.id] = index }

        for (child, body) in bodies.enumerated() {
            guard let parentID = body.parentID, let parent = indexByID[parentID], parent != child else { continue }
            let dx = bodies[parent].position.x - bodies[child].position.x
            let dy = bodies[parent].position.y - bodies[child].position.y
            let distance = max((dx * dx + dy * dy).squareRoot(), 0.01)
            let force = settings.spring * (distance - settings.idealEdgeLength)
            fx[child] += dx / distance * force
            fy[child] += dy / distance * force
            fx[parent] -= dx / distance * force
            fy[parent] -= dy / distance * force
        }

        // Roots are held loosely to where they were put.
        for (index, body) in bodies.enumerated() {
            guard body.parentID == nil, let home = body.home else { continue }
            fx[index] += (home.x - body.position.x) * settings.rootAnchor
            fy[index] += (home.y - body.position.y) * settings.rootAnchor
        }

        var moved = bodies
        for index in moved.indices where !moved[index].isPinned {
            let delta = clamped(x: fx[index], y: fy[index], to: settings.maxStep)
            moved[index].position = GraphPoint(x: moved[index].position.x + delta.x,
                                               y: moved[index].position.y + delta.y)
        }
        return moved
    }

    /// Run the simulation to (near) convergence — used to lay out a graph that arrives without
    /// positions, and by the tests.
    public static func relaxed(_ bodies: [Body],
                               iterations: Int = 300,
                               settings: Settings = Settings()) -> [Body] {
        var current = bodies
        for _ in 0..<max(0, iterations) {
            let next = step(current, settings: settings)
            let moved = maxDisplacement(from: current, to: next)
            current = next
            if moved < 0.05 { break }
        }
        return current
    }

    /// The furthest any node moved between two states — how the view decides the graph has settled
    /// and it can stop stepping (and write the positions back).
    public static func maxDisplacement(from before: [Body], to after: [Body]) -> Double {
        var positions: [UUID: GraphPoint] = [:]
        positions.reserveCapacity(before.count)
        for body in before { positions[body.id] = body.position }
        var worst: Double = 0
        for body in after {
            guard let was = positions[body.id] else { continue }
            let dx = body.position.x - was.x
            let dy = body.position.y - was.y
            worst = max(worst, (dx * dx + dy * dy).squareRoot())
        }
        return worst
    }

    private static func clamped(x: Double, y: Double, to limit: Double) -> (x: Double, y: Double) {
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > limit, magnitude > 0 else { return (x, y) }
        let scale = limit / magnitude
        return (x * scale, y * scale)
    }
}
