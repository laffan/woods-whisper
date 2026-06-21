import Foundation

public extension PromptPreset {
    /// Presets seeded on first launch. Users can edit, delete, or add their own.
    static let builtIns: [PromptPreset] = [
        PromptPreset(
            name: "Clean Up",
            template: "Lightly clean up the following transcript: fix punctuation, capitalization, "
                + "and obvious speech-to-text errors. Do not change wording or meaning.\n\n"
                + transcriptToken,
            temperature: 0.3,
            isBuiltIn: true
        ),
        PromptPreset(
            name: "Summarize",
            template: "Summarize the following transcript into a few concise bullet points "
                + "capturing the key ideas:\n\n" + transcriptToken,
            temperature: 0.4,
            isBuiltIn: true
        ),
        PromptPreset(
            name: "Action Items",
            template: "Extract any tasks, commitments, or action items from this transcript as a "
                + "checklist. If there are none, say so.\n\n" + transcriptToken,
            temperature: 0.3,
            isBuiltIn: true
        ),
        PromptPreset(
            name: "Formal Email",
            template: "Rewrite the following spoken notes as a clear, professional email. "
                + "Keep it concise.\n\n" + transcriptToken,
            temperature: 0.7,
            isBuiltIn: true
        ),
        PromptPreset(
            name: "Journal Entry",
            template: "Rewrite these spoken notes as a reflective first-person journal entry, "
                + "preserving the speaker's voice.\n\n" + transcriptToken,
            temperature: 0.8,
            isBuiltIn: true
        )
    ]
}
