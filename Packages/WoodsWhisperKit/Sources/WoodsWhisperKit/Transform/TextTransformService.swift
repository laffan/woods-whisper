import Foundation

/// Abstracts the on-device LLM (Gemma 3) so the UI depends on a protocol, not MLX directly.
public protocol TextTransformService: AnyObject {
    var isReady: Bool { get async }

    /// Which model is currently selected (e.g. "gemma-3-4b-it-4bit").
    var activeModel: GemmaModel { get }

    /// Switch the active model. May trigger a (one-time, online) download for that model.
    func setModel(_ model: GemmaModel) async throws

    /// Download/prepare the active model's weights. Call once during setup; offline after.
    func prepare() async throws

    /// Run a preset against a transcript, streaming tokens via `onToken`. Returns the full text.
    @discardableResult
    func transform(
        transcript: String,
        with preset: PromptPreset,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> String
}

/// Available on-device models. 4B is the default (runs on most modern devices); 12B is opt-in
/// for high-RAM devices (iPad Pro M-series, iPhone Pro 8 GB+).
public enum GemmaModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case gemma3_1B = "mlx-community/gemma-3-1b-it-4bit"
    case gemma3_4B = "mlx-community/gemma-3-4b-it-4bit"
    case gemma3_12B = "mlx-community/gemma-3-12b-it-4bit"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemma3_1B: return "Gemma 3 · 1B (fastest)"
        case .gemma3_4B: return "Gemma 3 · 4B (default)"
        case .gemma3_12B: return "Gemma 3 · 12B (high-RAM)"
        }
    }

    /// Rough minimum device RAM advisory, surfaced in Settings.
    public var approxRAMNote: String {
        switch self {
        case .gemma3_1B: return "~1.5 GB"
        case .gemma3_4B: return "~3.5 GB"
        case .gemma3_12B: return "~8 GB (iPad Pro / iPhone Pro only)"
        }
    }

    public static let `default`: GemmaModel = .gemma3_4B
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
