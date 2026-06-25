import Foundation

public extension PromptPreset {
    /// Presets seeded on first launch. Users can edit, delete, or add their own.
    static let builtIns: [PromptPreset] = [
        PromptPreset(
            name: "Clean Transcript",
            template: "The following text was automatically transcribed from dictation and does not "
                + "contain correct punctuation or formatting. Begin by removing all paragraph breaks, "
                + "attempted punctuation and bracketed text. Then, without changing any words, please "
                + "format and punctuate properly so that the sentences flow as best they can, adding "
                + "new paragraph breaks where appropriate.\n\n" + transcriptToken,
            temperature: 0.3,
            isBuiltIn: true
        ),
        PromptPreset(
            name: "Summarize Points",
            template: "Summarize the following in to a series of salient bullet points that capture "
                + "the main ideas.\n\n" + transcriptToken,
            temperature: 0.4,
            isBuiltIn: true
        ),
        PromptPreset(
            name: "Action Items",
            template: "Extract any tasks, commitments, or action items from this transcript as a "
                + "checklist. If there are none, say so.\n\n" + transcriptToken,
            temperature: 0.3,
            isBuiltIn: true
        )
    ]
}

