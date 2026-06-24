import Foundation

/// Abstracts the on-device LLM (Gemma 3) so the UI depends on a protocol, not MLX directly.
public protocol TextTransformService: AnyObject {
    var isReady: Bool { get async }

    /// Which model is currently selected (e.g. "Qwen3-4B-4bit").
    var activeModel: LanguageModelChoice { get }

    /// Switch the active model. Does not download — it only selects the model and drops any
    /// loaded weights, so `isReady` becomes false until `prepare` is called for the new model.
    func setModel(_ model: LanguageModelChoice) async throws

    /// Download/prepare the active model's weights. Call once during setup; offline after.
    /// Re-running resumes partial downloads. `progress` reports download fraction and byte counts.
    func prepare(progress: (@Sendable (DownloadProgress) -> Void)?) async throws

    /// Run a preset against a transcript, streaming tokens via `onToken`. Returns the full text.
    @discardableResult
    func transform(
        transcript: String,
        with preset: PromptPreset,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> String
}

/// Available on-device language models. Qwen3 4B is the default; Llama 3.2 3B and the two Gemma
/// sizes are selectable alternatives. All run 4-bit quantized via MLX on iPhone/iPad.
public enum LanguageModelChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    case qwen3_4B = "mlx-community/Qwen3-4B-4bit"
    case llama3_2_3B = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    case gemma3_4B = "mlx-community/gemma-3-4b-it-4bit"
    case gemma3_1B = "mlx-community/gemma-3-1b-it-4bit"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen3_4B:    return "Qwen3 · 4B (default)"
        case .llama3_2_3B: return "Llama 3.2 · 3B"
        case .gemma3_4B:   return "Gemma 3 · 4B"
        case .gemma3_1B:   return "Gemma 3 · 1B (fastest)"
        }
    }

    /// Rough minimum device RAM advisory, surfaced in Settings.
    public var approxRAMNote: String {
        switch self {
        case .qwen3_4B:    return "~3 GB"
        case .llama3_2_3B: return "~2.5 GB"
        case .gemma3_4B:   return "~3.5 GB"
        case .gemma3_1B:   return "~1.5 GB"
        }
    }

    /// Extra stop strings beyond the tokenizer's own end-of-sequence token. Chat models mark the
    /// end of a turn with a special token (Gemma's `<end_of_turn>`, Qwen/ChatML's `<|im_end|>`,
    /// Llama's `<|eot_id|>`); if the streaming loop doesn't treat that marker as a stop, generation
    /// runs away repeating it. The transform loop halts at the first of these it sees.
    public var stopSequences: [String] {
        switch self {
        case .qwen3_4B:
            return ["<|im_end|>", "<|endoftext|>"]
        case .llama3_2_3B:
            return ["<|eot_id|>", "<|end_of_text|>"]
        case .gemma3_4B, .gemma3_1B:
            return ["<end_of_turn>", "<eos>"]
        }
    }

    public static let `default`: LanguageModelChoice = .qwen3_4B
}

public enum TextTransformError: Error, LocalizedError {
    case modelNotPrepared
    case unsupportedPlatform
    case underlying(Error)

    public var errorDescription: String? {
        switch self {
        case .modelNotPrepared:
            return "Language model isn't downloaded yet. Complete setup while online once."
        case .unsupportedPlatform:
            return "The language model runs on iPhone/iPad, not on this device."
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}
