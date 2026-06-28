import Foundation

/// Abstracts the on-device LLM so the UI depends on a protocol, not MLX directly.
public protocol TextTransformService: AnyObject {
    var isReady: Bool { get async }

    /// Which model is currently selected (e.g. "gemma-3-4b-it-4bit").
    var activeModel: LanguageModelChoice { get }

    /// Switch the active model. Does not download — it only selects the model and drops any
    /// loaded weights, so `isReady` becomes false until `prepare` is called for the new model.
    func setModel(_ model: LanguageModelChoice) async throws

    /// Download/prepare the active model's weights. Call once during setup; offline after.
    /// Re-running resumes partial downloads. `progress` reports download fraction and byte counts.
    func prepare(progress: (@Sendable (DownloadProgress) -> Void)?) async throws

    /// Run a preset against a transcript, streaming tokens via `onToken` (tagged as the final
    /// answer or the model's reasoning). Returns the split result; the reasoning is *not* part of
    /// the answer.
    @discardableResult
    func transform(
        transcript: String,
        with preset: PromptPreset,
        onToken: (@Sendable (TransformToken) -> Void)?
    ) async throws -> TransformResult
}

/// A streamed piece of a transformation, tagged by where it belongs.
public enum TransformToken: Sendable {
    /// Part of the model's hidden reasoning (a `<think>…</think>` block). Shown collapsibly in the
    /// UI but excluded from the saved output.
    case reasoning(String)
    /// Part of the final answer — the text the user actually wants.
    case answer(String)
}

/// The outcome of a transformation: the final `answer`, plus any `reasoning` the model emitted in a
/// `<think>` block (nil when there was none). Reasoning is kept separate so it can be shown but
/// never becomes part of the answer that's saved, copied, or fed into further transforms.
public struct TransformResult: Sendable, Equatable {
    public var answer: String
    public var reasoning: String?

    public init(answer: String, reasoning: String? = nil) {
        self.answer = answer
        self.reasoning = reasoning
    }
}

/// Available language models. Most run **on-device** (4-bit quantized via MLX on iPhone/iPad):
/// Gemma 3 4B is the default; Qwen3 4B (which shows its reasoning), Llama 3.2 3B, and Gemma 3 1B
/// are selectable alternatives. Two **online** options — Anthropic's Claude Sonnet and Haiku — are
/// also selectable for when the device has a cell signal; these call the Anthropic API instead of
/// downloading weights, so they show an *Authenticate* step (an API key) rather than a *Download*.
///
/// The Gemma entries use Google's **QAT** (quantization-aware-trained) 4-bit weights. The plain
/// `…-it-4bit` community repos quantize some attention projections with a per-layer group size that
/// the MLX-Swift loader mis-reads ("Mismatched parameter … o_proj.biases … Actual [2560,32],
/// expected [2560,16]"); the QAT repos are uniformly quantized, so they load cleanly (and are a bit
/// higher quality).
public enum LanguageModelChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    case gemma3_4B = "mlx-community/gemma-3-4b-it-qat-4bit"
    case qwen3_4B = "mlx-community/Qwen3-4B-4bit"
    case llama3_2_3B = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    case gemma3_1B = "mlx-community/gemma-3-1b-it-qat-4bit"
    // Online (Anthropic). The rawValue doubles as the API `model` id.
    case claudeSonnet = "claude-sonnet-4-6"
    case claudeHaiku = "claude-haiku-4-5"

    public var id: String { rawValue }

    /// True for the cloud models (Anthropic). Online models stream from the Anthropic API over the
    /// network instead of running locally, so they need a cell/WiFi signal and an API key rather
    /// than a one-time weight download.
    public var isOnline: Bool {
        switch self {
        case .claudeSonnet, .claudeHaiku:                       return true
        case .gemma3_4B, .qwen3_4B, .llama3_2_3B, .gemma3_1B:   return false
        }
    }

    public var displayName: String {
        switch self {
        case .gemma3_4B:    return "Gemma 3 · 4B (default)"
        case .qwen3_4B:     return "Qwen3 · 4B (shows reasoning)"
        case .llama3_2_3B:  return "Llama 3.2 · 3B"
        case .gemma3_1B:    return "Gemma 3 · 1B (fastest)"
        case .claudeSonnet: return "Claude Sonnet 4.6 (online)"
        case .claudeHaiku:  return "Claude Haiku 4.5 (online)"
        }
    }

    /// Rough minimum device RAM advisory, surfaced in Settings. Online models run server-side, so
    /// they have no local RAM footprint.
    public var approxRAMNote: String {
        switch self {
        case .gemma3_4B:                  return "~3.5 GB"
        case .qwen3_4B:                   return "~3 GB"
        case .llama3_2_3B:                return "~2.5 GB"
        case .gemma3_1B:                  return "~1.5 GB"
        case .claudeSonnet, .claudeHaiku: return "runs in the cloud"
        }
    }

    /// Approximate on-disk download size (4-bit weights), shown inline in the model picker. Online
    /// models download nothing, so this reads "no download".
    public var approxDownloadSize: String {
        switch self {
        case .gemma3_4B:                  return "~2.4 GB"
        case .qwen3_4B:                   return "~2.3 GB"
        case .llama3_2_3B:                return "~1.8 GB"
        case .gemma3_1B:                  return "~0.7 GB"
        case .claudeSonnet, .claudeHaiku: return "no download"
        }
    }

    /// Picker label combining the model name and what it costs to enable, e.g. "Gemma 3 · 4B —
    /// ~2.4 GB" for an on-device model or "Claude Sonnet 4.6 (online) — needs cell signal" online.
    public var pickerLabel: String {
        isOnline ? "\(displayName) — needs cell signal" : "\(displayName) — \(approxDownloadSize)"
    }

    /// Extra stop strings beyond the tokenizer's own end-of-sequence token. Chat models mark the
    /// end of a turn with a special token (Gemma's `<end_of_turn>`, Qwen/ChatML's `<|im_end|>`,
    /// Llama's `<|eot_id|>`); if the streaming loop doesn't treat that marker as a stop, generation
    /// runs away repeating it. The transform loop halts at the first of these it sees. Online models
    /// stream from the Anthropic API, which signals turn-end itself, so they need none.
    public var stopSequences: [String] {
        switch self {
        case .qwen3_4B:
            return ["<|im_end|>", "<|endoftext|>"]
        case .llama3_2_3B:
            return ["<|eot_id|>", "<|end_of_text|>"]
        case .gemma3_4B, .gemma3_1B:
            return ["<end_of_turn>", "<eos>"]
        case .claudeSonnet, .claudeHaiku:
            return []
        }
    }

    /// Whether this model wraps its reasoning in a `<think>…</think>` block that should be split
    /// out of the answer. Only the Qwen3 "thinking" model does.
    public var usesThinkTags: Bool {
        switch self {
        case .qwen3_4B:
            return true
        case .gemma3_4B, .llama3_2_3B, .gemma3_1B, .claudeSonnet, .claudeHaiku:
            return false
        }
    }

    public static let `default`: LanguageModelChoice = .gemma3_4B
}

public enum TextTransformError: Error, LocalizedError {
    case modelNotPrepared
    case notAuthenticated
    case unsupportedPlatform
    case underlying(Error)

    public var errorDescription: String? {
        switch self {
        case .modelNotPrepared:
            return "Language model isn't downloaded yet. Complete setup while online once."
        case .notAuthenticated:
            return "This online model needs your Anthropic API key. Tap Authenticate in Settings → Language Model."
        case .unsupportedPlatform:
            return "The language model runs on iPhone/iPad, not on this device."
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}
