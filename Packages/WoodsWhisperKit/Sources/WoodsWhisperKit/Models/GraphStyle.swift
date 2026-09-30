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

// MARK: - Highlights

/// Obsidian's highlight: `==like this==`, drawn on the canvas as the words with a marker-pen wash
/// behind them and the `==` left out — the same bargain a heading's `#` makes. The stored text
/// keeps the markers, so opening the card shows them again, and so does the outline it exports.
///
/// The rules are Markdown's for emphasis, which is what Obsidian's parser follows: the two markers
/// have to be on the same line, with something between them, and the words have to sit *against*
/// them — `==this==` is a highlight, `== this ==` is two pairs of equals signs someone typed. A
/// marker that doesn't open a highlight stays in the text exactly as written.
public enum GraphHighlight {
    /// One stretch of a card's words: highlighted, or not.
    public struct Run: Hashable, Sendable {
        public let text: String
        public let isHighlighted: Bool

        public init(text: String, isHighlighted: Bool) {
            self.text = text
            self.isHighlighted = isHighlighted
        }
    }

    public static let marker = "=="

    /// `text` split into what's highlighted and what isn't, in order, with the markers taken out.
    /// Text with no highlight in it comes back as a single plain run (none at all when it's empty).
    public static func runs(in text: String) -> [Run] {
        var runs: [Run] = []
        var plain = ""
        var rest = text[...]
        while let open = rest.range(of: marker) {
            let afterOpen = rest[open.upperBound...]
            if let close = afterOpen.range(of: marker),
               isHighlightable(afterOpen[..<close.lowerBound]) {
                plain += rest[..<open.lowerBound]
                if !plain.isEmpty { runs.append(Run(text: plain, isHighlighted: false)) }
                plain = ""
                runs.append(Run(text: String(afterOpen[..<close.lowerBound]), isHighlighted: true))
                rest = afterOpen[close.upperBound...]
            } else {
                // Not a highlight: keep the marker as it was typed, and look again past it.
                plain += rest[..<open.upperBound]
                rest = afterOpen
            }
        }
        plain += rest
        if !plain.isEmpty { runs.append(Run(text: plain, isHighlighted: false)) }
        return runs
    }

    /// The words with every highlight's markers taken off — what a plain-text copy of a card says.
    public static func stripped(_ text: String) -> String {
        runs(in: text).map(\.text).joined()
    }

    /// Whether what sits between two markers can be a highlight: something, on one line, that
    /// neither starts nor ends with a space.
    private static func isHighlightable(_ inner: Substring) -> Bool {
        guard let first = inner.first, let last = inner.last else { return false }
        return !first.isWhitespace && !last.isWhitespace && !inner.contains(where: \.isNewline)
    }
}

// MARK: - Blockquotes

/// Markdown's blockquote: a line that opens with `>` is drawn on the canvas as a quotation — set in
/// from a bar down its left edge, in a quieter ink — with the marker left out, the same bargain a
/// heading's `#` and a highlight's `==` make. The stored text keeps it, so opening the card shows it
/// again, and so does the outline the graph exports (where `- > words` is a quotation inside a
/// bullet, which is Markdown in its own right).
///
/// It goes **line by line**, as Markdown does: a card can say something and then quote something,
/// and consecutive quoted lines run together into one quotation. `>>` — or `> >` — is a quotation
/// inside a quotation, and gets a second bar. The space after a `>` is optional, as it is in
/// Markdown.
///
/// One rule is stricter than Markdown's: a line *without* the marker ends the quotation. Markdown
/// lets a paragraph run on into the quote above it ("lazy continuation"); on a card that reads as
/// the quote swallowing the next line, which is never what someone typing a line under a quote
/// meant. And a marker with nothing after it isn't a quotation — it's someone half way through
/// typing one — so it stays in the text exactly as typed, as a heading's lone `#` does.
public enum GraphQuote {
    /// One stretch of a card's lines: ordinary text (`depth` 0), or a quotation `depth` deep.
    public struct Block: Hashable, Sendable {
        public let text: String
        public let depth: Int

        public init(text: String, depth: Int) {
            self.text = text
            self.depth = depth
        }

        public var isQuote: Bool { depth > 0 }
    }

    public static let marker: Character = ">"

    /// `text` split into ordinary stretches and quotations, in order, with the markers taken off.
    /// Text with no quotation in it comes back as one plain block (none at all when it's empty).
    public static func blocks(in text: String) -> [Block] {
        // Most cards quote nothing; don't take them apart line by line to find that out.
        guard text.contains(marker) else {
            let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return plain.isEmpty ? [] : [Block(text: plain, depth: 0)]
        }

        var blocks: [Block] = []
        var said: [Substring] = []      // the current run, markers off
        var typed: [Substring] = []     // the same lines, as typed
        var depth = 0

        func appendPlain(_ text: String) {
            guard !text.isEmpty else { return }
            if let last = blocks.last, !last.isQuote {
                blocks[blocks.count - 1] = Block(text: last.text + "\n" + text, depth: 0)
            } else {
                blocks.append(Block(text: text, depth: 0))
            }
        }

        func flush() {
            defer { said = []; typed = [] }
            let body = said.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if depth == 0 {
                appendPlain(body)
            } else if body.isEmpty {
                // Markers with nothing after them: not a quotation yet, so the text as it was typed.
                appendPlain(typed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                blocks.append(Block(text: body, depth: depth))
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let (lineDepth, rest) = parse(line)
            if lineDepth != depth, !typed.isEmpty { flush() }
            depth = lineDepth
            said.append(rest)
            typed.append(line)
        }
        flush()
        return blocks
    }

    /// Whether any of `text` is a quotation — the question the canvas asks before drawing a card
    /// as blocks rather than as one run of text.
    public static func containsQuote(_ text: String) -> Bool {
        blocks(in: text).contains(where: \.isQuote)
    }

    /// The words with every quotation's markers taken off, one block to a line — what a plain-text
    /// copy of a card says, and what the node list shows.
    public static func stripped(_ text: String) -> String {
        guard text.contains(marker) else { return text }
        return blocks(in: text).map(\.text).joined(separator: "\n")
    }

    /// How many quotation markers open `line`, and what's left once they (and the one optional
    /// space after each) are taken off. Leading spaces before the first marker are allowed, and so
    /// are spaces between nested ones: `> > this` is as deep as `>> this`.
    static func parse(_ line: Substring) -> (depth: Int, rest: Substring) {
        var rest = line.drop(while: { $0 == " " || $0 == "\t" })
        guard rest.first == marker else { return (0, line) }
        var depth = 0
        while rest.first == marker {
            depth += 1
            rest = rest.dropFirst()
            let spaced = rest.drop(while: { $0 == " " || $0 == "\t" })
            if spaced.first == marker {
                rest = spaced                    // another marker: nested
            } else if rest.first == " " {
                rest = rest.dropFirst()          // the one space Markdown lets a marker take
            }
        }
        return (depth, rest)
    }
}

// MARK: - A card that's a single emoji

/// A node that says one emoji and nothing else is drawn as that emoji, large, on a square card —
/// a marker on the map rather than a line of text. Anything more (a second emoji, a word, a `#`)
/// and it's an ordinary card again.
public enum GraphEmoji {
    /// Whether `text`, trimmed, is exactly one emoji.
    ///
    /// "One" is one *character* as a reader counts them — a family, a flag, a skin tone or a
    /// keycap is a single emoji built from several code points, and counts as one.
    public static func isSingleEmoji(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let character = trimmed.first else { return false }
        return isEmoji(character)
    }

    /// Whether one character is drawn as an emoji. Most are emoji by default (😀, 🌲, a flag). A
    /// handful of older symbols are *text* by default — ❤, ☺, and the digits a keycap is built
    /// on — and only count when something asks for the emoji: the variation selector, a skin tone,
    /// the keycap itself, a joined sequence. A bare digit or © is text, not a picture.
    static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        return first.properties.isEmoji && scalars.count > 1
    }
}
