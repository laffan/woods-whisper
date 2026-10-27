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
    /// A recording that's only a punctuation mark said by name ("comma", "question mark") puts in
    /// the mark rather than the word — on the end of the words it was spoken over, or of the word
    /// before the gap it was spoken into. Spoken over words, "wrap in …" wraps them ("wrap in
    /// parentheses", "wrap it in quotes", "wrap in em dashes"). See `SpokenCommand`.
    ///
    /// Returns the ids of the words that went in, in order — empty when nothing did — so the
    /// editor can select them. For a mark or a wrap, that's the words it went on.
    @discardableResult
    public mutating func finish(_ edit: Edit, with transcript: String?) -> [UUID] {
        if let transcript, let command = SpokenCommand(transcript),
           let touched = perform(command, for: edit) {
            return touched
        }
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
        let after = tokens[at...].first { !$0.isPlaceholder && !$0.isStruck }

        spoken[0].word = startsSentence(at: at) ? Self.capitalized(spoken[0].word)
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

    /// Whether a word put in at `index` would open a sentence: nothing before it, or the word
    /// before it ends one or ends a line.
    private func startsSentence(at index: Int) -> Bool {
        guard let before = tokens[..<index].last(where: { !$0.isPlaceholder && !$0.isStruck }) else {
            return true
        }
        return Self.endsSentence(before.word) || before.lineBreaks > 0
    }

    // MARK: Spoken punctuation

    /// A recording that says what to do with the words rather than what they should say.
    public enum SpokenCommand: Equatable {
        /// A punctuation mark said by name: "comma", "question mark", "em dash".
        case mark(String)
        /// "Wrap in parentheses", "wrap it in quotes" — said over words.
        case wrap(Wrapper)

        /// What can be wrapped around words. Bold and italic are Markdown's, `**` and `*`.
        public enum Wrapper: Equatable {
            case parentheses, brackets, quotes, singleQuotes, dashes, bold, italic
        }

        /// The names a mark can be said by, as they come back from the transcriber once lower-cased
        /// and stripped of punctuation ("Question mark?" → "question mark", "Em-dash." → "em dash").
        static let markNames: [String: String] = [
            "period": ".", "full stop": ".",
            "comma": ",",
            "question mark": "?",
            "exclamation mark": "!", "exclamation point": "!",
            "semicolon": ";", "semi colon": ";",
            "colon": ":",
            "dash": "—", "em dash": "—", "m dash": "—", "emdash": "—",
            "ellipsis": "…", "dot dot dot": "…",
        ]

        /// A transcript that's nothing but a mark, typed rather than named.
        static let bareMarks: [String: String] = [
            ".": ".", ",": ",", "?": "?", "!": "!", ";": ";", ":": ":",
            "…": "…", "...": "…", "—": "—", "–": "—", "-": "—", "--": "—",
        ]

        /// The command `transcript` is, or nil when it's words to put in.
        public init?(_ transcript: String) {
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if let mark = Self.bareMarks[trimmed] {
                self = .mark(mark)
                return
            }
            let words = trimmed.lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { !$0.isEmpty }
            if let mark = Self.markNames[words.joined(separator: " ")] {
                self = .mark(mark)
                return
            }
            // "Wrap [it] in …" — or "rap in", which is how the transcriber sometimes hears it.
            guard let verb = words.first, verb == "wrap" || verb == "rap" else { return nil }
            var rest = words.dropFirst()
            if let object = rest.first, ["it", "them", "that", "this", "these", "those"].contains(object) {
                rest = rest.dropFirst()
            }
            guard let preposition = rest.first, preposition == "in" || preposition == "with" else {
                return nil
            }
            let what = rest.dropFirst().joined(separator: " ")
            if what.contains("paren") {
                self = .wrap(.parentheses)
            } else if what.contains("bracket") {
                self = .wrap(.brackets)
            } else if what.contains("single") && what.contains("quot") {
                self = .wrap(.singleQuotes)
            } else if what.contains("quot") {
                self = .wrap(.quotes)
            } else if what.contains("dash") {
                self = .wrap(.dashes)
            } else if what.contains("bold") {
                self = .wrap(.bold)
            } else if what.contains("italic") {
                self = .wrap(.italic)
            } else {
                return nil
            }
        }
    }

    /// Carry out `command` for `edit`, returning the ids of the words it went on — or nil when it
    /// means nothing here (a wrap with no words to wrap), and what was said goes in as words.
    private mutating func perform(_ command: SpokenCommand, for edit: Edit) -> [UUID]? {
        switch edit {
        case .insert(let placeholderID):
            guard case .mark(let mark) = command else { return nil }
            var gap = tokens.count
            if let at = index(of: placeholderID) {
                tokens.remove(at: at)
                gap = at
            }
            return [punctuate(at: gap, with: mark)]

        case .replace(let ids):
            let doomed = Set(ids)
            let indices = tokens.indices.filter { doomed.contains(tokens[$0].id) }
            for index in indices { tokens[index].isPending = false }
            guard let first = indices.first, let last = indices.last else { return [] }
            let words = tokens[first...last].filter { !$0.isPlaceholder }.map(\.id)
            switch command {
            case .mark(let mark): punctuate(at: last + 1, with: mark)
            case .wrap(let wrapper): wrap(first...last, in: wrapper)
            }
            return words
        }
    }

    /// Put a punctuation mark in at `gap` — what saying its name over a gap does, asked for from
    /// the editor's hold menu instead. Returns the id of the word the mark went on.
    @discardableResult
    public mutating func insertMark(_ mark: String, at gap: Int) -> UUID {
        punctuate(at: gap, with: mark)
    }

    /// Put `mark` in at `gap`: on the end of the word before it — taking the place of the mark
    /// that word already ends with, so "comma" over "cat." makes "cat," — or, for a dash or with
    /// no word before it, as a word of its own. The word after is capitalised if the mark has just
    /// ended a sentence, and lower-cased if it's just stopped ending one. Returns the id of the
    /// word the mark is on.
    @discardableResult
    private mutating func punctuate(at gap: Int, with mark: String) -> UUID {
        let gap = min(max(gap, 0), tokens.count)
        guard mark != "—",
              let target = tokens[..<gap].lastIndex(where: { !$0.isPlaceholder && !$0.isStruck }) else {
            let atEnd = gap == tokens.count
            if atEnd, let last = tokens.indices.last, tokens[last].trailing.isEmpty {
                tokens[last].trailing = " "
            }
            let token = Token(word: mark, trailing: atEnd ? "" : " ")
            tokens.insert(token, at: gap)
            return token.id
        }
        var word = tokens[target].word
        let endedSentence = Self.closesSentence(word)
        if Self.closingPunctuation(of: word) != nil, !word.hasSuffix("..") { word.removeLast() }
        word += mark
        tokens[target].word = word

        let endsSentence = Self.closesSentence(word)
        if endsSentence != endedSentence,
           let next = tokens[(target + 1)...].firstIndex(where: { !$0.isPlaceholder && !$0.isStruck }),
           tokens[target..<next].allSatisfy({ $0.lineBreaks == 0 }) {
            tokens[next].word = endsSentence ? Self.capitalized(tokens[next].word)
                                             : Self.decapitalized(tokens[next].word)
        }
        return tokens[target].id
    }

    /// Wrap the words in `range`. Quotes go round everything, the closing punctuation included.
    /// Parentheses, brackets and Markdown's bold and italic close before it ("(a cat),",
    /// "**a cat**,"), unless the words are a sentence of their own. Dashes are words of their own,
    /// set off by spaces; a comma, semicolon or colon that closed the words is the dash's job now,
    /// and there's no dash at the start of a sentence or after its end.
    public mutating func wrap(_ range: ClosedRange<Int>, in wrapper: SpokenCommand.Wrapper) {
        guard tokens.indices.contains(range.lowerBound), tokens.indices.contains(range.upperBound) else { return }
        let first = range.lowerBound
        let last = range.upperBound
        let opensSentence = startsSentence(at: first)
        switch wrapper {
        case .quotes, .singleQuotes:
            let double = wrapper == .quotes
            tokens[first].word = (double ? "“" : "‘") + tokens[first].word
            tokens[last].word += double ? "”" : "’"
        case .parentheses, .brackets, .bold, .italic:
            let (open, close): (String, String)
            switch wrapper {
            case .parentheses: (open, close) = ("(", ")")
            case .brackets:    (open, close) = ("[", "]")
            case .bold:        (open, close) = ("**", "**")
            default:           (open, close) = ("*", "*")
            }
            tokens[first].word = open + tokens[first].word
            var word = tokens[last].word
            if !(opensSentence && Self.endsSentence(word)), let mark = Self.closingPunctuation(of: word),
               !word.hasSuffix("..") {
                word.removeLast()
                tokens[last].word = word + close + mark
            } else {
                tokens[last].word = word + close
            }
        case .dashes:
            if let mark = Self.closingPunctuation(of: tokens[last].word), ",;:".contains(mark) {
                tokens[last].word.removeLast()
            }
            let closes = !Self.endsSentence(tokens[last].word) && tokens[last].lineBreaks == 0
                && tokens[(last + 1)...].contains { !$0.isPlaceholder && !$0.isStruck }
            if closes { tokens.insert(Token(word: "—"), at: last + 1) }
            if !opensSentence { tokens.insert(Token(word: "—"), at: first) }
        }
    }

    // MARK: Stitching

    /// **Stitch** the words in `range` back into one run: the marks between them taken out and the
    /// capitals lowered — what a transcriber's stop-start sentences need ("I went. To the store."
    /// becomes "I went to the store."). Two things are kept, because they belong to what's around
    /// the words rather than to the words themselves: a capital that opens a sentence, and the mark
    /// that closes the last word. An apostrophe or hyphen inside a word is part of it ("don't",
    /// "well-known"), as is a point or comma inside a number ("3.5"), and "I" and an acronym keep
    /// their capitals. A word that was nothing but marks (a dash) goes. Line breaks stay.
    ///
    /// Returns the ids of the words left, in order — empty when there were none.
    @discardableResult
    public mutating func stitch(_ range: ClosedRange<Int>) -> [UUID] {
        guard tokens.indices.contains(range.lowerBound), tokens.indices.contains(range.upperBound) else {
            return []
        }
        let opens = startsSentence(at: range.lowerBound)
        let lastWord = range.reversed().first { !tokens[$0].isPlaceholder }
        var isFirst = true
        var emptied: [Int] = []
        for index in range where !tokens[index].isPlaceholder {
            let original = tokens[index].word
            var word = Self.unpunctuated(original)
            guard !word.isEmpty else {
                emptied.append(index)
                continue
            }
            word = isFirst && opens ? Self.capitalized(Self.lowered(word)) : Self.lowered(word)
            isFirst = false
            if index == lastWord { word += Self.closingMark(of: original) }
            tokens[index].word = word
        }
        // Taken out the way `delete` takes words out: a line break that followed one stays.
        for index in emptied.reversed() {
            if index > 0, tokens[index].lineBreaks > tokens[index - 1].lineBreaks {
                tokens[index - 1].trailing = tokens[index].trailing
            }
            tokens.remove(at: index)
        }
        let upper = range.upperBound - emptied.count
        guard range.lowerBound <= upper else { return [] }
        return tokens[range.lowerBound...upper].filter { !$0.isPlaceholder }.map(\.id)
    }

    /// The marks `stitch` takes out of a word: sentence punctuation, quotes, brackets and dashes.
    /// Anything else (%, $, &, /) is part of what the word says.
    private static let stitchedMarks = Set(".,;:!?…\"“”‘’'()[]{}—–-")

    /// `word` with its marks taken out, keeping an apostrophe or hyphen between two letters and a
    /// point, comma or colon between two digits.
    static func unpunctuated(_ word: String) -> String {
        let characters = Array(word)
        var kept = ""
        for (index, character) in characters.enumerated() {
            guard stitchedMarks.contains(character) else {
                kept.append(character)
                continue
            }
            guard index > 0, index < characters.count - 1 else { continue }
            let before = characters[index - 1]
            let after = characters[index + 1]
            if "'’-".contains(character), before.isLetter, after.isLetter {
                kept.append(character)
            } else if ".,:".contains(character), before.isNumber, after.isNumber {
                kept.append(character)
            }
        }
        return kept
    }

    /// The mark that ends `word`, looking past a closing quote or bracket — or nothing.
    static func closingMark(of word: String) -> String {
        let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
        guard let last = stripped.last, ".,;:!?…".contains(last) else { return "" }
        return String(last)
    }

    /// A word in lower case all through — except "I" and its contractions, and an acronym.
    static func lowered(_ word: String) -> String {
        let letters = word.filter(\.isLetter)
        if letters == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return word }
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return word }
        return word.lowercased()
    }

    /// Whether a word ends a sentence in a way that makes the next one start with a capital: a
    /// full stop, question or exclamation mark — not an ellipsis, which can trail off mid-sentence.
    static func closesSentence(_ word: String) -> Bool {
        endsSentence(word) && !word.hasSuffix("…")
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
