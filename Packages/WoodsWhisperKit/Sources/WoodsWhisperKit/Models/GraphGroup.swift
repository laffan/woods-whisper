import Foundation

/// A ring drawn round a handful of nodes on a graph canvas: "these belong together".
///
/// A group is deliberately *not* part of the tree. It has no parent, nothing hangs off it, and the
/// Markdown outline walks straight past it — it's a spatial annotation, the mind-map equivalent of
/// circling a cluster with a pencil. That's why membership is a plain list of ids rather than
/// anything structural: a node can be in a group and hang off a parent somewhere else entirely.
///
/// Membership is edited by *moving nodes*, not by managing a list: a node dragged inside the ring
/// joins, one dragged out leaves (see `DocumentStore.setGroupMembers`). The ring itself is drawn
/// around whatever the members' cards currently occupy, so it follows them without being stored.
public struct GraphGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID

    /// What the user called it, or empty — the label sits at the ring's top-left corner and is
    /// optional, since a group can be worth drawing before it's worth naming.
    public var label: String

    /// The nodes inside. An array rather than a `Set` so the JSON on disk is stable and readable;
    /// `members` is the set you'd want to compute with.
    public var memberIDs: [UUID]

    public let createdAt: Date

    public init(id: UUID = UUID(),
                label: String = "",
                memberIDs: [UUID] = [],
                createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.memberIDs = memberIDs
        self.createdAt = createdAt
    }

    public var members: Set<UUID> { Set(memberIDs) }

    public var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var hasLabel: Bool { !trimmedLabel.isEmpty }

    /// Fewer than this and there's nothing left to circle, so the group dissolves itself.
    public static let minimumMembers = 2
}
