import Foundation
import Security
import WoodsWhisperKit

/// Stores the user's Anthropic API key in the iOS Keychain (not UserDefaults — it's a secret).
/// The key is the only thing "Authenticate" collects; it's read on every online transform and can
/// be edited or cleared from Settings → Language Model.
enum AnthropicAPIKeyStore {
    private static let service = "com.woodswhisper.anthropic"
    private static let account = "api-key"

    /// The stored key, or nil if the user hasn't authenticated yet.
    static var apiKey: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    static var hasKey: Bool {
        guard let key = apiKey else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Save (or replace) the key. An empty/whitespace value clears it.
    static func setKey(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Online text transformation via the Anthropic Messages API (Claude Sonnet / Haiku). Implements
/// the same `TextTransformService` protocol as the on-device `GemmaTransformService`, so the rest
/// of the app is agnostic to whether a transform runs locally or in the cloud.
///
/// "Readiness" here means *authenticated* (an API key is present) rather than *downloaded* — there
/// are no weights to fetch. `transform` POSTs to `/v1/messages` with `stream: true` and forwards
/// each `text_delta` as a `.answer` token, mirroring the local streaming experience.
public final class AnthropicTransformService: TextTransformService {

    public private(set) var activeModel: LanguageModelChoice

    private let host = "https://api.anthropic.com"
    private let apiVersion = "2023-06-01"

    public init(model: LanguageModelChoice = .claudeSonnet) {
        self.activeModel = model
    }

    /// Online models are "ready" as soon as the user has authenticated. We don't validate the key
    /// against the network here — a bad key surfaces as an error on the first transform.
    public var isReady: Bool {
        get async { AnthropicAPIKeyStore.hasKey }
    }

    public func setModel(_ model: LanguageModelChoice) async throws {
        activeModel = model
    }

    /// Nothing to download. Treat a present key as "prepared"; otherwise tell the caller to
    /// authenticate (the Settings UI normally drives this via the Authenticate button instead).
    public func prepare(progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        guard AnthropicAPIKeyStore.hasKey else { throw TextTransformError.notAuthenticated }
    }

    @discardableResult
    public func transform(
        transcript: String,
        with preset: PromptPreset,
        onToken: (@Sendable (TransformToken) -> Void)? = nil
    ) async throws -> TransformResult {
        guard let apiKey = AnthropicAPIKeyStore.apiKey, !apiKey.isEmpty else {
            throw TextTransformError.notAuthenticated
        }
        let userPrompt = preset.render(with: transcript)

        var request = URLRequest(url: URL(string: "\(host)/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        // Sonnet 4.6 / Haiku 4.5 accept `temperature`; reuse the preset's so online results feel
        // like the local ones. The preset's system prompt becomes the API `system` field.
        let body: [String: Any] = [
            "model": activeModel.rawValue,
            "max_tokens": preset.maxTokens,
            "temperature": preset.temperature,
            "stream": true,
            "system": preset.systemPrompt,
            "messages": [["role": "user", "content": userPrompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        wwLog("Anthropic transform starting (\(activeModel.displayName))", .transform)
        var answer = ""
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TextTransformError.underlying(URLError(.badServerResponse))
            }
            guard (200..<300).contains(http.statusCode) else {
                // Drain the SSE/JSON error body so we can surface the real reason (bad key, etc.).
                var detail = ""
                for try await line in bytes.lines { detail += line }
                throw TextTransformError.underlying(AnthropicAPIError(statusCode: http.statusCode, body: detail))
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }   // SSE: ignore `event:` and blanks
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, payload != "[DONE]",
                      let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String else { continue }

                switch type {
                case "content_block_delta":
                    if let delta = json["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta",
                       let text = delta["text"] as? String, !text.isEmpty {
                        answer += text
                        onToken?(.answer(text))
                    }
                case "error":
                    let message = (json["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                    throw TextTransformError.underlying(AnthropicAPIError(statusCode: nil, body: message))
                default:
                    break
                }
            }
            wwLog("Anthropic transform finished (\(answer.count) chars)", .transform)
            return TransformResult(answer: answer.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as TextTransformError {
            wwLog("Anthropic transform failed: \(error.localizedDescription)", .error)
            throw error
        } catch {
            wwLog("Anthropic transform failed: \(error.localizedDescription)", .error)
            throw TextTransformError.underlying(error)
        }
    }
}

/// A readable wrapper around a non-2xx Anthropic API response (or a streamed `error` event), so the
/// UI shows "HTTP 401 …" instead of a generic networking message.
struct AnthropicAPIError: LocalizedError {
    let statusCode: Int?
    let body: String

    var errorDescription: String? {
        let message = extractedMessage ?? body
        if let statusCode { return "Anthropic API error (HTTP \(statusCode)): \(message)" }
        return "Anthropic API error: \(message)"
    }

    /// Pull `error.message` out of an Anthropic JSON error body when present.
    private var extractedMessage: String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }
}
