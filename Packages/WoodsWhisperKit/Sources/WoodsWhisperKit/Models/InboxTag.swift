import Foundation

/// A tag as it's configured: what it's called, and which ink it's drawn in.
///
/// The name is the identity — it's what a `Recording` stores and what the matching below compares —
/// so renaming a tag in Settings makes a new one rather than renaming what entries carry. That's
/// the honest behaviour for something an entry keeps a copy of.
public struct InboxTagStyle: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    /// One of `InboxTag.paletteIDs`.
    public var colorID: String

    public var id: String { name }

    public init(name: String, colorID: String) {
        self.name = name
        self.colorID = colorID
    }
}

/// What an Inbox entry can be filed under, and how an entry files itself.
///
/// A tag is a plain string — the list of them is a setting the user edits, and an entry keeps the
/// name it was filed under rather than a reference into that list, so renaming or dropping a tag
/// never takes an entry's meaning with it.
///
/// The interesting half is the automatic filing. Say "Question — where does the trail cross the
/// creek?" and the entry files itself under **Question** without being asked, because that's how
/// people already speak into a capture app: the first word says what kind of thing this is. Which
/// means the match has to be forgiving about *how* it was said — "questions", "fixed", "reminders"
/// are all the same intent — without being so forgiving that an ordinary sentence beginning with a
/// coincidence gets filed. Stems, compared exactly, are the line this draws.
public enum InboxTag {
    /// The inks a tag can be drawn in, named rather than defined: this package has no colours in it
    /// (it compiles for the Watch, which draws none of this), so the app maps each id to one of its
    /// own — see `WW.tagColor(_:)` — and holds the light and dark versions there.
    public static let paletteIDs = ["moss", "violet", "amber", "slate", "ember", "ink"]

    /// What the Inbox starts with, before anyone edits the list in Settings — three tags, three
    /// colours, so they tell themselves apart the first time you see them.
    public static let defaultStyles = [
        InboxTagStyle(name: "Question", colorID: "violet"),
        InboxTagStyle(name: "Reminder", colorID: "amber"),
        InboxTagStyle(name: "Fix", colorID: "moss")
    ]

    /// Just the names — what the matching below works on, and what a `Recording` stores.
    public static var defaultNames: [String] { defaultStyles.map(\.name) }

    /// A colour for a tag being added: the first one nothing else is wearing, so a new tag stands
    /// apart without anyone having to choose. Once every colour is taken it starts round again.
    public static func nextColorID(notIn used: [String]) -> String {
        paletteIDs.first { !used.contains($0) } ?? paletteIDs[used.count % paletteIDs.count]
    }

    /// The tag this text files itself under, if its **first word** says so — otherwise nil, which is
    /// most text. Ties go to the earlier tag in the list, so the order in Settings is the priority.
    public static func autoTag(for text: String, from tags: [String]) -> String? {
        guard let first = text.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let word = stem(String(first))
        guard !word.isEmpty else { return nil }
        return tags.first { stem($0) == word }
    }

    /// `text` with the tag word it opens with taken off — once a first word has filed an entry, it's
    /// said what it had to say, and the tag's pill and edge carry it from then on. The marks that
    /// set it off from the rest go with it ("Question — where…", "Reminder: water filter"), and
    /// what's left starts with a capital. Nil when the first word isn't `tag`, or when it's all
    /// there is: an entry that says nothing but its tag keeps the word rather than becoming empty.
    public static func removingTagWord(_ tag: String, from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: { $0.isWhitespace }).first,
              matches(String(first), tag: tag) else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,;:!?…—–-"))
        var rest = Substring(trimmed[first.endIndex...])
        while let character = rest.first,
              character.unicodeScalars.allSatisfy({ separators.contains($0) }) {
            rest = rest.dropFirst()
        }
        guard let opening = rest.first else { return nil }
        return opening.isLowercase ? opening.uppercased() + rest.dropFirst() : String(rest)
    }

    /// Whether a word is a tag, or a version of it: same stem, nothing more.
    public static func matches(_ word: String, tag: String) -> Bool {
        let stemmed = stem(word)
        return !stemmed.isEmpty && stemmed == stem(tag)
    }

    /// A word reduced to what it's about: lowercased, stripped of everything that isn't a letter
    /// (so "Question:" and "question" are the same word), then shortened past the endings that only
    /// say how it was used — "fixed" and "fixes" and "fixing" are all *fix*, "reminders" is
    /// *remind*, and so is "reminder".
    ///
    /// Endings come off repeatedly, because a word can carry two ("reminders" → "reminder" →
    /// "remind"), and never below three letters, which is what keeps short tags like "fix" whole
    /// rather than stemming them away to nothing.
    static func stem(_ word: String) -> String {
        var value = word.lowercased().filter(\.isLetter)
        let endings = ["ing", "ers", "er", "ed", "es", "s"]
        var trimmed = true
        while trimmed {
            trimmed = false
            for ending in endings
            where value.hasSuffix(ending) && value.count - ending.count >= 3 {
                value.removeLast(ending.count)
                trimmed = true
                break
            }
        }
        return value
    }
}
