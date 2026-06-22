import Foundation
import WoodsWhisperKit

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

// MLXLLM also declares a `GemmaModel` (the neural-net module). Disambiguate every
// unqualified use in this file to our model-choice enum from the kit.
private typealias GemmaModel = WoodsWhisperKit.GemmaModel

/// Gemma 3 text transformation via MLX Swift. iOS/iPadOS only.
///
/// On platforms without MLX (the Watch) every method throws `.unsupportedPlatform`, so the
/// type compiles everywhere and the Watch target links without the LLM dependency.
///
/// NOTE: like the ASR service, MLX's example API moves over time. Calls below target the
/// `LLMModelFactory` / `ModelContainer` / `MLXLMCommon.generate` surface. Verify against the
/// resolved version and tweak the marked lines; the app depends only on `TextTransformService`.
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
            let configuration = ModelConfiguration(id: activeModel.rawValue)            // (1)
            container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) // (2)
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

        do {
            return try await container.perform { context in
                let chat: [Chat.Message] = [
                    .system(preset.systemPrompt),
                    .user(userPrompt)
                ]
                let input = try await context.processor.prepare(input: .init(messages: chat))   // (3)
                let params = GenerateParameters(temperature: Float(preset.temperature))

                var output = ""
                let stream = try MLXLMCommon.generate(
                    input: input, parameters: params, context: context
                )
                for await item in stream {
                    if let chunk = item.chunk {
                        output += chunk
                        onToken?(chunk)
                    }
                }
                return output
            }
        } catch {
            throw TextTransformError.underlying(error)
        }
        #else
        throw TextTransformError.unsupportedPlatform
        #endif
    }
}
