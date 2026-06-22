import Foundation
import WoodsWhisperKit

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import MLXHuggingFace   // #huggingFaceLoadModelContainer macro + hub/tokenizer macros
import HuggingFace      // HubClient (referenced by the macro expansion)
import Tokenizers       // AutoTokenizer (referenced by the macro expansion)
#endif

// MLXLLM also declares a `GemmaModel` (the neural-net module). Disambiguate every
// unqualified use in this file to our model-choice enum from the kit. Must be public
// because it appears in this type's public API below.
public typealias GemmaModel = WoodsWhisperKit.GemmaModel

/// Gemma 3 text transformation via MLX Swift. iOS/iPadOS only.
///
/// Loads the model with the `#huggingFaceLoadModelContainer` macro (HF download + tokenizer)
/// and generates via `ChatSession.streamResponse`. On platforms without MLX (the Watch) every
/// method throws `.unsupportedPlatform`, so the type compiles everywhere and the Watch target
/// links without the LLM dependency.
public final class GemmaTransformService: TextTransformService {

    public private(set) var activeModel: GemmaModel

    #if canImport(MLXLLM)
    private var container: ModelContainer?
    #endif

    public init(model: GemmaModel = .default) {
        self.activeModel = model
    }

    public var isReady: Bool {
        get async {
            #if canImport(MLXLLM)
            return container != nil
            #else
            return false
            #endif
        }
    }

    public func setModel(_ model: GemmaModel) async throws {
        guard model != activeModel else { return }
        activeModel = model
        #if canImport(MLXLLM)
        container = nil          // force reload of the new weights on next prepare()
        try await prepare()
        #else
        throw TextTransformError.unsupportedPlatform
        #endif
    }

    public func prepare() async throws {
        #if canImport(MLXLLM)
        do {
            // Downloads weights on first run, then loads from the local HF cache (offline).
            // The macro injects the HuggingFace hub downloader + tokenizer loader; the variant
            // with a progressHandler lets us stream download progress to the Log.
            let configuration = ModelConfiguration(id: activeModel.rawValue)
            let throttle = ProgressThrottle(label: "Gemma weights")
            container = try await #huggingFaceLoadModelContainer(configuration: configuration) { progress in
                throttle.report(progress)
            }
        } catch {
            throw TextTransformError.underlying(error)
        }
        #else
        throw TextTransformError.unsupportedPlatform
        #endif
    }

    @discardableResult
    public func transform(
        transcript: String,
        with preset: PromptPreset,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        #if canImport(MLXLLM)
        guard let container else { throw TextTransformError.modelNotPrepared }
        let userPrompt = preset.render(with: transcript)

        let params = GenerateParameters(maxTokens: preset.maxTokens,
                                        temperature: Float(preset.temperature))
        // A fresh session per run: the system prompt is the instructions, and we stream tokens.
        let session = ChatSession(container,
                                  instructions: preset.systemPrompt,
                                  generateParameters: params)
        do {
            var output = ""
            for try await chunk in session.streamResponse(to: userPrompt) {
                output += chunk
                onToken?(chunk)
            }
            return output
        } catch {
            throw TextTransformError.underlying(error)
        }
        #else
        throw TextTransformError.unsupportedPlatform
        #endif
    }
}
