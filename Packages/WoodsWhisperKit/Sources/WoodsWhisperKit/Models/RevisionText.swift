import Foundation

/// A piece of text as the **Revise** editor holds it: word by word, each word able to be struck
/// through, replaced by something spoken over it, or have something spoken in beside it.
///
/// Words rather than characters, because the editor is worked with a finger: a swipe selects whole
/// words, a hold lands in the gap between two, and a word is the smallest thing a fingertip can
/// reliably pick out of a line. Each word keeps the whitespace that followed it, so a line break in
/// the text survives the round trip.
///
/// Struck words stay in the text while it's being revised — they're what a hold replaces — and are
/// taken out of what's saved (`revisedText`): striking a word through is how you say it should go.
public struct RevisionText: Equatable {

    public struct Token: Identifiable, Equatable {
        public let id: UUID
        public var word: String
        /// The whitespace after the word, as written: a space, a line break, or nothing at the end.
        public var trailing: String
        public var isStruck: Bool
        /// Waiting on the words being transcribed to take its place.
        public var isPending: Bool
        /// Stands where spoken words are about to go in, until they arrive.
        public var isPlaceholder: Bool

        public init(id: UUID = UUID(), word: String, trailing: String = " ", isStruck: Bool = false,
                    isPending: Bool = false, isPlaceholder: Bool = false) {
            self.id = id
            self.word = word
            self.trailing = trailing
            self.isStruck = isStruck
            self.isPending = isPending
            self.isPlaceholder = isPlaceholder
        }

        /// How many line breaks follow the word: one starts a new line, two leave a blank one.
        public var lineBreaks: Int { trailing.filter(\.isNewline).count }
    }

    /// An edit that's been started — a recording made — and is waiting on its words.
    public enum Edit: Equatable {
        /// The words with these ids are to be replaced.
        case replace([UUID])
        /// The words go in where this placeholder stands.
        case insert(UUID)
    }

    public private(set) var tokens: [Token]
    private let original: String

    public init(_ text: String) {
        tokens = Self.tokens(from: text)
        original = Self.render(tokens)
    }

    /// Split text into words, each carrying the whitespace that follows it.
    public static func tokens(from text: String) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        var trailing = ""
        for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character.isWhitespace {
                trailing.append(character)
            } else {
                if !trailing.isEmpty {
                    tokens.append(Token(word: word, trailing: trailing))
                    word = ""
                    trailing = ""
                }
                word.append(character)
            }
        }
        if !word.isEmpty { tokens.append(Token(word: word, trailing: "")) }
        return tokens
    }

    // MARK: What it says

    /// What saving the revision writes back: struck words taken out, placeholders left out, and a
    /// line break that followed a struck word kept, so taking out the end of a line doesn't run it
    /// into the next one.
    public var revisedText: String {
        var kept: [Token] = []
        for token in tokens {
            if token.isStruck || token.isPlaceholder {
                if let last = kept.indices.last, token.lineBreaks > kept[last].lineBreaks {
                    kept[last].trailing = token.trailing
                }
                continue
            }
            kept.append(token)
        }
        return Self.render(kept)
    }

    /// Whether saving would change anything.
    public var hasChanges: Bool { revisedText != original }

    /// Whether an edit is still waiting on its words.
    public var hasPendingEdit: Bool { tokens.contains { $0.isPending || $0.isPlaceholder } }

    private static func render(_ tokens: [Token]) -> String {
        tokens.map { $0.word + $0.trailing }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func index(of id: UUID) -> Int? { tokens.firstIndex { $0.id == id } }

    // MARK: Striking through

    /// Strike the words in `range` through, or take the strike off them.
    public mutating func setStruck(_ struck: Bool, in range: ClosedRange<Int>) {
        for index in range where tokens.indices.contains(index) && !tokens[index].isPlaceholder {
            tokens[index].isStruck = struck
        }
    }

    /// The run of struck-through words around `index` — what a hold on one of them replaces, and a
    /// triple tap un-strikes. Nil when the word there isn't struck.
    public func struckRun(around index: Int) -> ClosedRange<Int>? {
        func struck(_ i: Int) -> Bool {
            tokens.indices.contains(i) && tokens[i].isStruck && !tokens[i].isPlaceholder
        }
        guard struck(index) else { return nil }
        var lower = index
        var upper = index
        while struck(lower - 1) { lower -= 1 }
        while struck(upper + 1) { upper += 1 }
        return lower...upper
    }

    // MARK: Deleting

    /// Take the words in `range` out now, rather than striking them through for Done to leave out.
    /// A line break that followed them is kept, as it is for struck words, so deleting the end of a
    /// line doesn't run it into the next one. Placeholders stay where they are.
    public mutating func delete(_ range: ClosedRange<Int>) {
        guard tokens.indices.contains(range.lowerBound), tokens.indices.contains(range.upperBound) else { return }
        let doomed = tokens[range].filter { !$0.isPlaceholder }
        guard let last = doomed.last else { return }
        let ids = Set(doomed.map(\.id))
        let before = range.lowerBound - 1
        if tokens.indices.contains(before), last.lineBreaks > tokens[before].lineBreaks {
            tokens[before].trailing = last.trailing
        }
        tokens.removeAll { ids.contains($0.id) }
    }

    // MARK: Replacing it all

    /// Put `text` in place of everything — a transform's answer. What it's compared against for
    /// `hasChanges` stays the text the revision opened with.
    public mutating func replaceAll(with text: String) {
        tokens = Self.tokens(from: text)
    }

    // MARK: Sentences

    /// The sentence the word at `index` belongs to — what a single tap selects. A sentence ends on
    /// a word that closes one (a full stop, question or exclamation mark, ellipsis) or at a line
    /// break, so a line with no punctuation, or a section of a whole document, is a sentence too.
    /// Nil when `index` is out of range.
    public func sentence(around index: Int) -> ClosedRange<Int>? {
        guard tokens.indices.contains(index) else { return nil }
        // A placeholder's "…" only holds a spot; it doesn't end anything.
        func ends(_ i: Int) -> Bool {
            (!tokens[i].isPlaceholder && Self.endsSentence(tokens[i].word)) || tokens[i].lineBreaks > 0
        }
        var lower = index
        while lower > 0, !ends(lower - 1) { lower -= 1 }
        var upper = index
        while upper < tokens.count - 1, !ends(upper) { upper += 1 }
        return lower...upper
    }

    // MARK: Speaking over and in

    /// Begin replacing the words in `range`: they're marked as waiting, and stay on screen until
    /// what was said in their place arrives.
    public mutating func beginReplacing(_ range: ClosedRange<Int>) -> Edit {
        var ids: [UUID] = []
        for index in range where tokens.indices.contains(index) && !tokens[index].isPlaceholder {
            tokens[index].isPending = true
            ids.append(tokens[index].id)
        }
        return .replace(ids)
    }

    /// Begin inserting in front of the word at `gap` (`tokens.count` for the very end): a
    /// placeholder holds the spot until the words arrive.
    public mutating func beginInserting(at gap: Int) -> Edit {
        let gap = min(max(gap, 0), tokens.count)
        let atEnd = gap == tokens.count
        if atEnd, let last = tokens.indices.last, tokens[last].trailing.isEmpty {
            tokens[last].trailing = " "
        }
        let placeholder = Token(word: "…", trailing: atEnd ? "" : " ", isPlaceholder: true)
        tokens.insert(placeholder, at: gap)
        return .insert(placeholder.id)
    }

    /// The words for `edit` have arrived — or haven't (`nil` or nothing said), in which case the
    /// text goes back to how it was before the edit began.
    ///
    /// Spoken words are fitted to where they land: lower-cased in the middle of a sentence and
    /// capitalised at the start of one, a full stop dropped when the sentence carries on after
    /// them, and the punctuation that closed a replaced word kept on the end of its replacement.
    ///
    /// Returns the ids of the words that went in, in order — empty when nothing did — so the
    /// editor can select them.
    @discardableResult
    public mutating func finish(_ edit: Edit, with transcript: String?) -> [UUID] {
        var spoken = Self.tokens(from: transcript ?? "")

        switch edit {
        case .insert(let placeholderID):
            guard let at = index(of: placeholderID) else {
                // The spot has gone; what was said still has to land somewhere.
                return append(spoken)
            }
            let placeholder = tokens.remove(at: at)
            guard !spoken.isEmpty else { return [] }
            spoken[spoken.count - 1].trailing = placeholder.trailing
            fit(&spoken, at: at, replacing: nil)
            tokens.insert(contentsOf: spoken, at: at)

        case .replace(let ids):
            let doomed = Set(ids)
            let indices = tokens.indices.filter { doomed.contains(tokens[$0].id) }
            guard !spoken.isEmpty else {
                for index in indices { tokens[index].isPending = false }
                return []
            }
            guard let first = indices.first, let last = indices.last else {
                return append(spoken)
            }
            let replaced = tokens[last]
            tokens.removeAll { doomed.contains($0.id) }
            spoken[spoken.count - 1].trailing = replaced.trailing
            let at = min(first, tokens.count)
            fit(&spoken, at: at, replacing: replaced.word)
            tokens.insert(contentsOf: spoken, at: at)
        }
        return spoken.map(\.id)
    }

    private mutating func append(_ spoken: [Token]) -> [UUID] {
        guard !spoken.isEmpty else { return [] }
        if let last = tokens.indices.last, tokens[last].trailing.isEmpty { tokens[last].trailing = " " }
        var spoken = spoken
        fit(&spoken, at: tokens.count, replacing: nil)
        tokens.append(contentsOf: spoken)
        return spoken.map(\.id)
    }

    // MARK: Moving

    /// Whether moving `range` to `gap` would go anywhere: a gap inside the words, or at either
    /// edge of them, leaves them where they are.
    public static func moves(_ range: ClosedRange<Int>, to gap: Int) -> Bool {
        gap < range.lowerBound || gap > range.upperBound + 1
    }

    /// Move the words in `range` to `gap` — counted, like every gap, as the index of the word it
    /// comes before in the text as it stands (the token count for the very end). The words keep
    /// their ids, so a selection stays on them. A line break that ended the words stays where it
    /// was rather than travelling with them, so lifting the end of a line doesn't join it to the
    /// next one.
    public mutating func move(_ range: ClosedRange<Int>, to gap: Int) {
        guard tokens.indices.contains(range.lowerBound), tokens.indices.contains(range.upperBound),
              Self.moves(range, to: gap), gap >= 0, gap <= tokens.count else { return }
        var moved = Array(tokens[range])
        let lastTrailing = moved[moved.count - 1].trailing
        tokens.removeSubrange(range)
        let before = range.lowerBound - 1
        if tokens.indices.contains(before), moved[moved.count - 1].lineBreaks > tokens[before].lineBreaks {
            tokens[before].trailing = lastTrailing
        }
        let at = gap > range.upperBound ? gap - moved.count : gap
        if at == tokens.count {
            if let last = tokens.indices.last, tokens[last].trailing.isEmpty { tokens[last].trailing = " " }
            moved[moved.count - 1].trailing = ""
        } else {
            moved[moved.count - 1].trailing = " "
        }
        tokens.insert(contentsOf: moved, at: at)
    }

    /// Fit spoken words to the sentence they're going into at `at`. `replacedLast` is the last word
    /// they replace, whose closing punctuation they inherit if they have none of their own.
    private func fit(_ spoken: inout [Token], at: Int, replacing replacedLast: String?) {
        guard !spoken.isEmpty else { return }
        let before = tokens[..<at].last { !$0.isPlaceholder && !$0.isStruck }
        let after = tokens[at...].first { !$0.isPlaceholder && !$0.isStruck }

        let startsSentence = before.map { Self.endsSentence($0.word) || $0.lineBreaks > 0 } ?? true
        spoken[0].word = startsSentence ? Self.capitalized(spoken[0].word)
                                        : Self.decapitalized(spoken[0].word)

        let lastIndex = spoken.count - 1
        if let replacedLast, let mark = Self.closingPunctuation(of: replacedLast),
           Self.closingPunctuation(of: spoken[lastIndex].word) == nil {
            spoken[lastIndex].word += mark
        } else if let after, after.word.first?.isLowercase == true,
                  spoken[lastIndex].word.hasSuffix("."), !spoken[lastIndex].word.hasSuffix("..") {
            // The sentence carries on after what was said, so a full stop the transcriber put on
            // the end isn't the end of anything.
            spoken[lastIndex].word.removeLast()
        }
    }

    // MARK: Words and sentences

    static func endsSentence(_ word: String) -> Bool {
        let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
        guard let last = stripped.last else { return false }
        return ".!?…".contains(last)
    }

    static func closingPunctuation(of word: String) -> String? {
        guard let last = word.last, ".,;:!?".contains(last) else { return nil }
        return String(last)
    }

    static func capitalized(_ word: String) -> String {
        guard let first = word.first, first.isLowercase else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// Lower-case a word's first letter, leaving alone the words that are capitalised wherever
    /// they stand: "I" and its contractions, and anything that's capitals all through (an
    /// acronym). A name is the one thing this can't tell — it takes the transcriber's word for a
    /// capital only at the start of a sentence.
    static func decapitalized(_ word: String) -> String {
        guard let first = word.first, first.isUppercase else { return word }
        let letters = word.filter(\.isLetter)
        if letters == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return word }
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return word }
        return first.lowercased() + word.dropFirst()
    }
}
