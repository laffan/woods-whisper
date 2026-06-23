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
        // Just switch — drop the loaded weights so `isReady` is false until `prepare` is called
        // for the new model. The UI's Download button drives the (one-time, online) fetch.
        container = nil
        wwLog("Language model switched to \(model.displayName) — download required before use", .model)
        #else
        throw TextTransformError.unsupportedPlatform
        #endif
    }

    public func prepare(progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        #if canImport(MLXLLM)
        // Downloads weights on first run (re-running resumes via the HF cache), then loads from
        // the local cache (offline). The macro injects the HuggingFace hub downloader + tokenizer
        // loader; its progressHandler variant streams download progress as a `Foundation.Progress`.
        let configuration = ModelConfiguration(id: activeModel.rawValue)
        wwLog("Language model download starting: \(activeModel.rawValue)", .model)
        let throttle = ProgressThrottle(label: "Gemma weights")
        let stall = DownloadStallMonitor(label: "Gemma weights")
        stall.start()
        defer { stall.stop() }
        do {
            container = try await #huggingFaceLoadModelContainer(configuration: configuration) { p in
                stall.update(p.fractionCompleted)
                throttle.report(p)
                progress?(DownloadProgress(p))
            }
            wwLog("Language model weights loaded into memory", .model)
        } catch {
            // Surface the real cause — a wrapped URLError reads as a generic "operation couldn't
            // be completed", which is exactly the unhelpful output the log was missing.
            wwLog("Language model download failed: \(Self.describe(error))", .error)
            throw TextTransformError.underlying(error)
        }
        #else
        throw TextTransformError.unsupportedPlatform
        #endif
    }

    /// A debugging-friendly description that pulls a connection diagnosis out of a `URLError`.
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "connection error (\(urlError.code)): \(urlError.localizedDescription)"
        }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
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
