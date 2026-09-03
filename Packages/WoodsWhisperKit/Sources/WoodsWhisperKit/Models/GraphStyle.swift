import Foundation

/// How a node or a group on a graph canvas is *drawn*, as far as anything outside the app can say:
/// which ink it was given, and whether its first line marks it as a heading.
///
/// Both are text-and-numbers questions, so they live here where they can be tested, rather than in
/// the canvas that answers them with fonts and colours.

// MARK: - Colour

/// The inks a node or a group can be given, named rather than defined.
///
/// This package draws nothing (it compiles for the Watch), so a colour is a stored id and the app
/// maps it to one of its own — see `WW.paletteColor(_:)`, which holds the light and dark versions.
/// It's deliberately the same set of names an Inbox tag uses: one vocabulary of colour across the
/// app, so "the amber one" means the same thing wherever it's said.
public enum GraphPalette {
    /// The ids on offer, in the order a colour menu lists them.
    public static let colorIDs = InboxTag.paletteIDs

    /// Whether an id is one this app knows how to draw. A node saved by a later build — or hand-
    /// edited — keeps whatever it stored; this is what the *menu* checks before ticking a row.
    public static func isKnown(_ colorID: String?) -> Bool {
        guard let colorID else { return false }
        return colorIDs.contains(colorID)
    }
}

// MARK: - Headings

/// A node whose text opens with `#` or `##`: a heading, drawn bigger and bold on the canvas, with
/// the marker itself left out of what's shown.
///
/// One `#` is the larger of the two, `##` the smaller — Markdown's own ordering, and the same
/// characters you'd have typed in the outline this graph exports as. Three or more isn't a size the
/// canvas draws, so `### like this` stays ordinary text with its hashes visible: better to show
/// exactly what was typed than to silently swallow a marker nothing came of.
public struct GraphHeading: Hashable, Sendable {
    /// 1 for `#`, 2 for `##`.
    public let level: Int
    /// What's left once the marker (and the space after it) is taken off — what the card shows.
    public let text: String

    public init(level: Int, text: String) {
        self.level = level
        self.text = text
    }

    /// How many points bigger than the body this heading is set: a clear step for `#`, a smaller
    /// one for `##`, so the two read as different sizes rather than as the same one twice.
    public var extraPoints: Double { level == 1 ? 7 : 4 }

    /// The heading `raw` opens with, or nil — which is most text.
    ///
    /// A marker with nothing after it (`#`, or `##` and a space) isn't a heading: it's someone
    /// half way through typing one, or a stray character, and either way there's nothing to make
    /// large. It stays plain text with its hashes showing.
    public static func parse(_ raw: String) -> GraphHeading? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = text[...]
        var level = 0
        while rest.first == "#" {
            level += 1
            rest = rest.dropFirst()
        }
        guard level == 1 || level == 2 else { return nil }
        let body = String(rest).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return GraphHeading(level: level, text: body)
    }
}
