import Foundation

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
    /// What the Inbox starts with, before anyone edits the list in Settings.
    public static let defaults = ["Question", "Reminder", "Fix"]

    /// The tag this text files itself under, if its **first word** says so — otherwise nil, which is
    /// most text. Ties go to the earlier tag in the list, so the order in Settings is the priority.
    public static func autoTag(for text: String, from tags: [String]) -> String? {
        guard let first = text.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let word = stem(String(first))
        guard !word.isEmpty else { return nil }
        return tags.first { stem($0) == word }
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
