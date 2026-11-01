import Foundation

/// Configurable OpenAI-compatible chat endpoint for the cloud voice pipeline.
/// Defaults preserve the previously hardcoded DeepSeek official endpoint; the
/// homelab Hermes server (OpenAI-compatible, e.g. http://100.77.205.126:8648/v1)
/// can be used instead. The API key itself stays in the Keychain under the
/// existing CloudVoiceKeys.llmService entry — it is just a bearer credential,
/// so the Keychain service name does not need to follow the host.
enum CloudLLMEndpointSettings {
    struct Endpoint: Equatable {
        var baseURL: String
        var model: String

        /// OpenAI-compatible chat completions path appended to the base.
        var chatCompletionsURL: String { baseURL + "/chat/completions" }
        /// DeepSeek accepts a nonstandard `thinking` flag; other OpenAI-compatible
        /// servers may reject unknown fields, so only send it for DeepSeek models.
        var isDeepSeek: Bool { model.lowercased().hasPrefix("deepseek") }
    }

    static let baseURLKey = "cloudLLM.v1.baseURL"
    static let modelKey = "cloudLLM.v1.model"
    static let defaultBaseURL = "https://api.deepseek.com"
    static let defaultModel = "deepseek-v4-flash"

    static var current: Endpoint {
        let defaults = UserDefaults.standard
        let base = normalize(defaults.string(forKey: baseURLKey)) ?? defaultBaseURL
        let model = (defaults.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Endpoint(baseURL: base, model: model.isEmpty ? defaultModel : model)
    }

    static func save(baseURL rawBase: String?, model rawModel: String?) -> Bool {
        let defaults = UserDefaults.standard
        if let rawBase {
            guard let normalized = normalize(rawBase) else { return false }
            defaults.set(normalized, forKey: baseURLKey)
        }
        if let rawModel {
            let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, model.count <= 128,
                  !model.contains(where: { $0.isWhitespace }) else { return false }
            defaults.set(model, forKey: modelKey)
        }
        return true
    }

    /// Accepts http(s) base URLs only (LAN Hermes over http is allowed for dev;
    /// the app already enables NSAllowsLocalNetworking). No credentials, query
    /// or fragment; trailing slashes are removed; no path rewrite otherwise.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var url = URLComponents(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        url.scheme = scheme
        url.host = host.lowercased()
        if url.port == (scheme == "https" ? 443 : 80) { url.port = nil }
        while url.percentEncodedPath.hasSuffix("/") { url.percentEncodedPath.removeLast() }
        url.path = url.path.isEmpty ? "" : url.path
        return url.string
    }
}
