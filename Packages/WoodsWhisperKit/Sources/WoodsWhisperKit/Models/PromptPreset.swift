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
