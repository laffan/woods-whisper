import Foundation

/// A reusable text-transformation instruction applied to a transcript by the on-device LLM.
///
/// The `template` may contain the token `{{transcript}}`, which is substituted with the
/// document's transcript (or selected text) at run time. If the token is absent, the
/// transcript is appended after the template.
public struct PromptPreset: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var systemPrompt: String
    public var template: String
    /// Optional generation tuning per preset.
    public var temperature: Double
    public var maxTokens: Int
    /// Built-in presets ship with the app and can be reset; user presets are editable/deletable.
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        systemPrompt: String = PromptPreset.defaultSystemPrompt,
        template: String,
        temperature: Double = 0.7,
        maxTokens: Int = 1024,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.template = template
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.isBuiltIn = isBuiltIn
    }

    public static let transcriptToken = "{{transcript}}"

    /// Stable id of the built-in "Number Paragraphs" preset. This transform is applied
    /// deterministically (prefixing each paragraph with its ordinal) rather than run through the
    /// LLM, so callers key off this id to take the local path.
    public static let numberParagraphsID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    /// True for the built-in "Number Paragraphs" preset, which is handled locally, not by the model.
    public var isNumberParagraphs: Bool { id == Self.numberParagraphsID }

    /// Prefix each blank-line-separated block with its ordinal ("1. ", "2. ", …) — the deterministic
    /// implementation behind the "Number Paragraphs" transform.
    public static func numberParagraphs(in text: String) -> String {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return blocks.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n\n")
    }

    public static let defaultSystemPrompt =
        "You are a careful writing assistant operating fully offline on a personal device. "
        + "Follow the user's instruction precisely and return only the transformed text."

    /// Build the final user prompt for a given transcript.
    public func render(with transcript: String) -> String {
        if template.contains(Self.transcriptToken) {
            return template.replacingOccurrences(of: Self.transcriptToken, with: transcript)
        }
        return template + "\n\n" + transcript
    }
}
