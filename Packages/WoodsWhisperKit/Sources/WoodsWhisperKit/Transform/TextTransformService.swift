import Foundation

/// Abstracts the on-device LLM so the UI depends on a protocol, not MLX directly.
public protocol TextTransformService: AnyObject {
    var isReady: Bool { get async }

    /// Which model is currently selected (e.g. "LFM2.5-1.2B-Instruct-MLX-4bit").
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

/// Available language models. On-device there is one: Liquid AI's **LFM2.5 1.2B Instruct** (4-bit
/// MLX weights, running on iPhone/iPad) — small and quick, which is what tidying a transcript wants.
/// Two **online** options — Anthropic's Claude Sonnet and Haiku — are also selectable for when the
/// device has a cell signal; these call the Anthropic API instead of downloading weights, so they
/// show an *Authenticate* step (an API key) rather than a *Download*.
///
/// (The 2.6B was here too, briefly. It's a reasoning model, and on a phone it spent long enough
/// thinking — for results no better than the small one's — that it wasn't worth the wait.)
///
/// LFM2.5 checkpoints declare the `lfm2` architecture, which `mlx-swift-lm` implements, and their
/// chat template is ChatML-shaped — hence `<|im_end|>` as the turn-end stop.
public enum LanguageModelChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    // The rawValue is the HuggingFace repo the weights are pulled from — the LM Studio community's
    // 4-bit MLX conversion of Liquid AI's model.
    case lfm2_5_1_2B = "lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit"
    // Online (Anthropic). The rawValue doubles as the API `model` id.
    case claudeSonnet = "claude-sonnet-4-6"
    case claudeHaiku = "claude-haiku-4-5"

    public var id: String { rawValue }

    /// True for the cloud models (Anthropic). Online models stream from the Anthropic API over the
    /// network instead of running locally, so they need a cell/WiFi signal and an API key rather
    /// than a one-time weight download.
    public var isOnline: Bool {
        switch self {
        case .claudeSonnet, .claudeHaiku:   return true
        case .lfm2_5_1_2B:                  return false
        }
    }

    public var displayName: String {
        switch self {
        case .lfm2_5_1_2B:  return "LFM2.5 · 1.2B (default)"
        case .claudeSonnet: return "Claude Sonnet 4.6"
        case .claudeHaiku:  return "Claude Haiku 4.5"
        }
    }

    /// A compact label for inline use (e.g. the document Transform button: "Transform — Haiku 4.5").
    public var shortName: String {
        switch self {
        case .lfm2_5_1_2B:  return "LFM2.5 1.2B"
        case .claudeSonnet: return "Sonnet 4.6"
        case .claudeHaiku:  return "Haiku 4.5"
        }
    }

    /// Rough minimum device RAM advisory, surfaced in Settings. Online models run server-side, so
    /// they have no local RAM footprint.
    public var approxRAMNote: String {
        switch self {
        case .lfm2_5_1_2B:                return "~1 GB"
        case .claudeSonnet, .claudeHaiku: return "runs in the cloud"
        }
    }

    /// Approximate on-disk download size (4-bit weights), shown inline in the model picker. Online
    /// models download nothing, so this reads "no download".
    public var approxDownloadSize: String {
        switch self {
        case .lfm2_5_1_2B:                return "~0.7 GB"
        case .claudeSonnet, .claudeHaiku: return "no download"
        }
    }

    /// Extra stop strings beyond the tokenizer's own end-of-sequence token. Chat models mark the
    /// end of a turn with a special token (LFM2's ChatML-style `<|im_end|>`); if the streaming loop
    /// doesn't treat that marker as a stop, generation runs away repeating it. The transform loop
    /// halts at the first of these it sees. Online models stream from the Anthropic API, which
    /// signals turn-end itself, so they need none.
    public var stopSequences: [String] {
        switch self {
        case .lfm2_5_1_2B:
            return ["<|im_end|>", "<|endoftext|>"]
        case .claudeSonnet, .claudeHaiku:
            return []
        }
    }

    /// Whether this model wraps its reasoning in a `<think>…</think>` block that should be split out
    /// of the answer. Nothing in the current lineup thinks — the one that did was slow enough on a
    /// phone to be dropped — so this is the hook a future reasoning model hangs on rather than a
    /// live setting. `ThinkSplitter` keeps its half of the bargain either way: reasoning never
    /// reaches the saved text.
    public var usesThinkTags: Bool {
        switch self {
        case .lfm2_5_1_2B, .claudeSonnet, .claudeHaiku:
            return false
        }
    }

    /// Whether the *template* opens the reasoning block, so generation begins already inside it —
    /// as LFM2.5-2.6B's did, its prompt ending with `<think>` because the model was expected to
    /// think rather than to say it would. Only meaningful alongside `usesThinkTags`.
    public var opensThinkBlockInTemplate: Bool {
        switch self {
        case .lfm2_5_1_2B, .claudeSonnet, .claudeHaiku:     return false
        }
    }

    public static let `default`: LanguageModelChoice = .lfm2_5_1_2B

    /// Models that used to be in this list, by the repo their weights were downloaded from.
    ///
    /// Kept so the app can clear those weights off the device: they're gigabytes each, the picker no
    /// longer offers them, and without this there'd be no way left to ask for them to go.
    public static let retiredRepos: [String] = [
        "mlx-community/gemma-3-4b-it-qat-4bit",
        "mlx-community/Qwen3-4B-4bit",
        "mlx-community/Llama-3.2-3B-Instruct-4bit",
        "mlx-community/gemma-3-1b-it-qat-4bit",
        "LiquidAI/LFM2.5-2.6B-MLX-4bit"
    ]
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
