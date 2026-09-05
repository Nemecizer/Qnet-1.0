import Foundation
import Security

// MARK: - Provider

enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openai
    case ollama
    case lmstudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude API)"
        case .openai:    return "OpenAI"
        case .ollama:    return "Ollama (local)"
        case .lmstudio:  return "LM Studio (local)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai:    return "https://api.openai.com/v1"
        case .ollama:    return "http://localhost:11434"
        case .lmstudio:  return "http://localhost:1234/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-6"
        case .openai:    return "gpt-4o-mini"
        case .ollama:    return "llama3.2"
        case .lmstudio:  return "local-model"
        }
    }

    /// Curated list of models known to work well with Qnet's tool-use
    /// surface. Surfaced as a quick-pick menu in Settings; the Model field
    /// remains free-form so users can type any custom name (e.g. a
    /// fine-tune, a less-common Ollama tag, or an LM Studio local id).
    var recommendedModels: [String] {
        switch self {
        case .anthropic:
            return [
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5"
            ]
        case .openai:
            return [
                "gpt-4o-mini",
                "gpt-4o",
                "gpt-4-turbo",
                "gpt-4.1",
                "gpt-4.1-mini"
            ]
        case .ollama:
            return [
                "llama3.1:8b",
                "llama3.1:70b",
                "llama3.2",
                "llama3.3:70b",
                "qwen2.5:7b",
                "qwen2.5:14b",
                "qwen2.5:32b",
                "mistral-nemo"
            ]
        case .lmstudio:
            return [
                "llama-3.1-8b-instruct",
                "llama-3.3-70b-instruct",
                "qwen2.5-7b-instruct",
                "qwen2.5-14b-instruct",
                "mistral-nemo-instruct-2407"
            ]
        }
    }

    /// Curated quick-pick base URLs for each provider. The Base URL
    /// field stays free-form; this list is just a shortcut so users
    /// don't have to type out the common LAN/localhost endpoints.
    var recommendedBaseURLs: [String] {
        switch self {
        case .anthropic:
            return ["https://api.anthropic.com"]
        case .openai:
            return ["https://api.openai.com/v1"]
        case .ollama:
            return [
                "http://localhost:11434",
                "http://127.0.0.1:11434"
            ]
        case .lmstudio:
            return [
                "http://localhost:1234/v1",
                "http://127.0.0.1:1234/v1"
            ]
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .anthropic, .openai: return true
        case .ollama, .lmstudio:  return false
        }
    }

    /// Probe the provider's server for the list of model identifiers it
    /// will accept right now. Used by the Settings dropdown's refresh
    /// button to populate the menu with what's actually loaded /
    /// available rather than the static curated `recommendedModels`.
    ///
    /// - LM Studio + OpenAI: `GET <baseURL>/models` → `data[].id`.
    /// - Ollama: `GET <baseURL>/api/tags` → `models[].name`.
    /// - Anthropic: `GET https://api.anthropic.com/v1/models` with
    ///   `x-api-key` and `anthropic-version: 2023-06-01` → `data[].id`.
    ///
    /// LM Studio's endpoint only returns models that are currently
    /// loaded into the local server (not everything you've downloaded).
    /// Ollama similarly returns local models. OpenAI returns the full
    /// hosted catalog including legacy ids. Anthropic returns the full
    /// hosted catalog as well.
    func discoverModels(baseURL: String, apiKey: String) async throws -> [String] {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedBase.isEmpty else {
            throw LLMError.notConfigured("Base URL is empty.")
        }

        let endpoint: String
        switch self {
        case .anthropic:
            endpoint = "https://api.anthropic.com/v1/models"
        case .openai, .lmstudio:
            endpoint = trimmedBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                + "/models"
        case .ollama:
            endpoint = trimmedBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                + "/api/tags"
        }
        guard let url = URL(string: endpoint) else {
            throw LLMError.notConfigured("Invalid model-list endpoint: \(endpoint)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        switch self {
        case .anthropic:
            guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw LLMError.notConfigured("API key required to list Anthropic models.")
            }
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw LLMError.notConfigured("API key required to list OpenAI models.")
            }
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .lmstudio, .ollama:
            break
        }

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw LLMError.http(http.statusCode, snippet)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("Could not parse model-list response.")
        }

        switch self {
        case .anthropic, .openai, .lmstudio:
            guard let arr = obj["data"] as? [[String: Any]] else {
                throw LLMError.decoding("Missing `data[]` in model-list response.")
            }
            return arr.compactMap { $0["id"] as? String }.sorted()
        case .ollama:
            guard let arr = obj["models"] as? [[String: Any]] else {
                throw LLMError.decoding("Missing `models[]` in /api/tags response.")
            }
            return arr.compactMap { $0["name"] as? String }.sorted()
        }
    }
}

// MARK: - Wire types

/// A single content block within an `LLMMessage`. Anthropic-style block
/// model: assistant replies and user messages can mix plain text with tool
/// calls (the model asks to invoke a tool) and tool results (we feed
/// execution output back in). `@unchecked Sendable` because the
/// `[String: Any]` JSON payloads can't be proven Sendable by the compiler
/// but are used as value-semantic snapshots — we never share one across
/// threads for mutation.
enum LLMContent: @unchecked Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(id: String, content: String, isError: Bool)
}

struct LLMMessage: @unchecked Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: [LLMContent]

    init(role: Role, content: [LLMContent]) {
        self.role = role
        self.content = content
    }

    /// Convenience for a plain-text message.
    init(role: Role, text: String) {
        self.role = role
        self.content = [.text(text)]
    }
}

/// Wire-level tool metadata sent to the LLM provider. Deliberately has no
/// Swift-side handler so it's safe to cross actor boundaries. The full
/// `ToolDefinition` (with handler) lives in AITools.swift and exposes
/// `schema` to build instances of this.
struct LLMTool: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

struct LLMConfig {
    var provider: LLMProvider
    var baseURL: String
    var model: String
    var apiKey: String
    var systemPrompt: String
    var maxTokens: Int
    var temperature: Double
    var timeoutSeconds: Double
}

enum LLMError: LocalizedError {
    case notConfigured(String)
    case transport(String)
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let msg): return "AI backend not configured: \(msg)"
        case .transport(let msg):     return "Network error: \(msg)"
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .decoding(let msg):       return "Response parse error: \(msg)"
        }
    }
}

// MARK: - Client protocol

protocol LLMClient: Sendable {
    /// Sends the conversation plus a (possibly-empty) tool catalog and
    /// returns the assistant's response as one or more content blocks.
    /// Backends that don't support tool use drop the tool list and always
    /// return `.text(...)` blocks.
    func send(history: [LLMMessage], tools: [LLMTool]) async throws -> [LLMContent]
}

/// Whether a provider supports server-side tool use. Used by `AIModel` to
/// decide if it should even offer tools in the request.
extension LLMProvider {
    /// Whether the provider's wire adapter implements the structured
    /// tools[] / tool_calls round-trip. All four backends now do; what
    /// determines whether tool calls actually FIRE on a local backend
    /// is the loaded model's tool-call training (Llama 3.1+, Qwen
    /// 2.5+, recent Mistral instruct releases work; older / smaller
    /// models silently fall back to plain prose because they don't
    /// know how to emit `tool_calls`).
    var supportsToolUse: Bool {
        switch self {
        case .anthropic, .openai, .lmstudio, .ollama: return true
        }
    }
}

// MARK: - Factory

enum LLMClientFactory {
    static func make(from config: LLMConfig) throws -> LLMClient {
        if config.model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LLMError.notConfigured("Model name is empty.")
        }
        if config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LLMError.notConfigured("Base URL is empty.")
        }
        if config.provider.requiresAPIKey,
           config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LLMError.notConfigured("API key is required for \(config.provider.displayName).")
        }
        switch config.provider {
        case .anthropic:
            return AnthropicClient(config: config)
        case .openai, .lmstudio:
            return OpenAIClient(config: config)
        case .ollama:
            return OllamaClient(config: config)
        }
    }
}

// MARK: - Anthropic (Messages API) — supports tool use

struct AnthropicClient: LLMClient {
    let config: LLMConfig

    func send(history: [LLMMessage], tools: [LLMTool]) async throws -> [LLMContent] {
        guard var url = URL(string: config.baseURL) else {
            throw LLMError.notConfigured("Invalid base URL.")
        }
        url.append(path: "/v1/messages")

        // Serialize each LLMMessage into Anthropic's content-block format.
        // Anthropic treats tool_use / tool_result as ordinary content
        // blocks inside assistant / user messages respectively.
        let messages: [[String: Any]] = history.map { msg in
            let blocks: [[String: Any]] = msg.content.map { block in
                switch block {
                case .text(let t):
                    return ["type": "text", "text": t]
                case .toolUse(let id, let name, let input):
                    return [
                        "type":  "tool_use",
                        "id":    id,
                        "name":  name,
                        "input": input
                    ]
                case .toolResult(let id, let result, let isError):
                    var b: [String: Any] = [
                        "type":         "tool_result",
                        "tool_use_id":  id,
                        "content":      result
                    ]
                    if isError { b["is_error"] = true }
                    return b
                }
            }
            return ["role": msg.role.rawValue, "content": blocks]
        }

        var body: [String: Any] = [
            "model":      config.model,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "messages":   messages
        ]

        let sys = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { body["system"] = sys }

        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                [
                    "name":         t.name,
                    "description":  t.description,
                    "input_schema": t.inputSchema
                ] as [String: Any]
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await sendRequest(req)
        try ensureOK(resp, data: data)

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw LLMError.decoding("Missing `content` array in Anthropic response.")
        }

        var out: [LLMContent] = []
        for item in content {
            switch item["type"] as? String {
            case "text":
                if let t = item["text"] as? String { out.append(.text(t)) }
            case "tool_use":
                if let id    = item["id"]    as? String,
                   let name  = item["name"]  as? String,
                   let input = item["input"] as? [String: Any] {
                    out.append(.toolUse(id: id, name: name, input: input))
                }
            default:
                break
            }
        }
        if out.isEmpty {
            throw LLMError.decoding("Anthropic response had no usable content blocks.")
        }
        return out
    }
}

// MARK: - OpenAI (Chat Completions) / LM Studio (OpenAI-compatible)

struct OpenAIClient: LLMClient {
    let config: LLMConfig

    func send(history: [LLMMessage], tools: [LLMTool]) async throws -> [LLMContent] {
        guard var url = URL(string: config.baseURL) else {
            throw LLMError.notConfigured("Invalid base URL.")
        }
        url.append(path: "/chat/completions")

        // Two paths:
        //   * Tools enabled (caller passed a non-empty catalog) — build
        //     the structured request: tools[] wrapped in {type:function},
        //     prior assistant tool calls under `tool_calls`, prior tool
        //     results as separate {role:tool} messages keyed by
        //     tool_call_id. This is the format every modern Chat
        //     Completions–compatible backend (OpenAI, Azure OpenAI,
        //     vLLM, tool-trained LM Studio models) expects.
        //   * Tools disabled (caller passed []) — flatten history into
        //     plain text user/assistant messages. Used by chat-only
        //     callers (currently LM Studio via its supportsToolUse=false
        //     gate) so prior tool blocks survive as bracketed text and
        //     a non-tool-trained local model isn't confused by a
        //     `tool_calls` field it doesn't understand.
        let messages = tools.isEmpty
            ? buildFlatMessages(history: history)
            : buildStructuredMessages(history: history)

        var body: [String: Any] = [
            "model":       config.model,
            "messages":    messages,
            "max_tokens":  config.maxTokens,
            "temperature": config.temperature,
            "stream":      false
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                [
                    "type": "function",
                    "function": [
                        "name":        t.name,
                        "description": t.description,
                        "parameters":  t.inputSchema
                    ] as [String: Any]
                ] as [String: Any]
            }
            body["tool_choice"] = "auto"
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await sendRequest(req)
        try ensureOK(resp, data: data)

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw LLMError.decoding("Missing `choices[0].message` in response.")
        }

        // Either `content` is a non-empty string OR `tool_calls` is a
        // non-empty array (or both). OpenAI emits `content: null` when
        // the model only wanted to call tools, so the old "content
        // must be String" guard would reject perfectly valid tool-call
        // responses.
        var out: [LLMContent] = []
        if let text = message["content"] as? String, !text.isEmpty {
            out.append(.text(text))
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                guard let id = tc["id"] as? String,
                      let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String
                else { continue }
                // OpenAI's `arguments` is a JSON-encoded *string*, not
                // a parsed object. Decode it here so the tool dispatcher
                // sees the same `[String: Any]` shape it would from
                // Anthropic's `input` field.
                let argsStr = (function["arguments"] as? String) ?? "{}"
                let argsData = argsStr.data(using: .utf8) ?? Data("{}".utf8)
                let input = (try? JSONSerialization.jsonObject(with: argsData))
                    as? [String: Any] ?? [:]
                out.append(.toolUse(id: id, name: name, input: input))
            }
        }
        if out.isEmpty {
            throw LLMError.decoding(
                "OpenAI response had neither `content` nor `tool_calls`."
            )
        }
        return out
    }

    /// Chat-only path: collapse every block into plain text so the
    /// resulting messages array conforms to the original Chat
    /// Completions schema (only role + string content per message).
    func buildFlatMessages(history: [LLMMessage]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        let sys = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        for m in history {
            let text = flattenToText(m.content)
            guard !text.isEmpty else { continue }
            messages.append(["role": m.role.rawValue, "content": text])
        }
        return messages
    }

    /// Tool-aware path: split each `LLMMessage` into the OpenAI shape.
    /// User messages with `toolResult` blocks become one or more
    /// `role: tool` messages (one per result, keyed by tool_call_id).
    /// Assistant messages with `toolUse` blocks attach a `tool_calls`
    /// array; the matching `arguments` is JSON-encoded as a *string*
    /// to match OpenAI's wire format.
    func buildStructuredMessages(history: [LLMMessage]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        let sys = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        for m in history {
            switch m.role {
            case .user:
                var textParts: [String] = []
                var toolMessages: [[String: Any]] = []
                for c in m.content {
                    switch c {
                    case .text(let t):
                        if !t.isEmpty { textParts.append(t) }
                    case .toolResult(let id, let content, _):
                        toolMessages.append([
                            "role":         "tool",
                            "tool_call_id": id,
                            "content":      content
                        ])
                    case .toolUse:
                        // toolUse blocks shouldn't appear in user
                        // messages, but if they do, fall through as
                        // plain text so nothing is silently dropped.
                        textParts.append(flattenToText([c]))
                    }
                }
                if !textParts.isEmpty {
                    messages.append([
                        "role":    "user",
                        "content": textParts.joined(separator: "\n")
                    ])
                }
                // Tool results follow the assistant's tool_calls in the
                // OpenAI schema, so emit them after any user text.
                messages.append(contentsOf: toolMessages)

            case .assistant:
                var textParts: [String] = []
                var toolCalls: [[String: Any]] = []
                for c in m.content {
                    switch c {
                    case .text(let t):
                        if !t.isEmpty { textParts.append(t) }
                    case .toolUse(let id, let name, let input):
                        let argsData = (try? JSONSerialization.data(
                            withJSONObject: input,
                            options: [.sortedKeys]
                        )) ?? Data("{}".utf8)
                        let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                        toolCalls.append([
                            "id":   id,
                            "type": "function",
                            "function": [
                                "name":      name,
                                "arguments": argsStr
                            ] as [String: Any]
                        ])
                    case .toolResult:
                        // toolResult blocks shouldn't appear in
                        // assistant messages; ignore.
                        break
                    }
                }
                guard !textParts.isEmpty || !toolCalls.isEmpty else { continue }
                var msg: [String: Any] = ["role": "assistant"]
                // OpenAI requires `content` to be either a string or
                // null when `tool_calls` is present. NSNull bridges to
                // JSON null via JSONSerialization.
                msg["content"] = textParts.isEmpty
                    ? NSNull()
                    : textParts.joined(separator: "\n")
                if !toolCalls.isEmpty {
                    msg["tool_calls"] = toolCalls
                }
                messages.append(msg)
            }
        }
        return messages
    }
}

// MARK: - Ollama (native chat API)

struct OllamaClient: LLMClient {
    let config: LLMConfig

    func send(history: [LLMMessage], tools: [LLMTool]) async throws -> [LLMContent] {
        guard var url = URL(string: config.baseURL) else {
            throw LLMError.notConfigured("Invalid base URL.")
        }
        url.append(path: "/api/chat")

        // Same dual-path setup as OpenAIClient: when tools are
        // requested, build Ollama's structured message shape; when
        // they aren't, fall through to the legacy text-flatten path
        // so prior tool blocks survive as bracketed text and a
        // chat-only caller doesn't pay the structuring cost.
        let messages = tools.isEmpty
            ? buildFlatMessages(history: history)
            : buildStructuredMessages(history: history)

        var body: [String: Any] = [
            "model":    config.model,
            "messages": messages,
            "stream":   false,
            "options":  [
                "temperature": config.temperature,
                "num_predict": config.maxTokens
            ]
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                [
                    "type": "function",
                    "function": [
                        "name":        t.name,
                        "description": t.description,
                        "parameters":  t.inputSchema
                    ] as [String: Any]
                ] as [String: Any]
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await sendRequest(req)
        try ensureOK(resp, data: data)

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any] else {
            throw LLMError.decoding("Missing `message` in Ollama response.")
        }

        var out: [LLMContent] = []
        if let text = message["content"] as? String, !text.isEmpty {
            out.append(.text(text))
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                guard let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String
                else { continue }
                // Ollama delivers `arguments` as a parsed JSON object
                // (unlike OpenAI, which stringifies it). It also doesn't
                // emit a per-call `id` field — Qnet's `LLMContent.toolUse`
                // requires one for the dispatcher to thread results back,
                // so we synthesize a UUID locally. Result-side matching
                // stays positional on the way back to Ollama (see
                // buildStructuredMessages) since Ollama never sees the ID.
                let input = (function["arguments"] as? [String: Any]) ?? [:]
                let id = "ollama-\(UUID().uuidString)"
                out.append(.toolUse(id: id, name: name, input: input))
            }
        }
        if out.isEmpty {
            throw LLMError.decoding(
                "Ollama response had neither `content` nor `tool_calls`."
            )
        }
        return out
    }

    /// Chat-only path: collapse every block (including any prior
    /// tool calls / results from a different provider) into plain
    /// text so the request fits the original Ollama chat schema.
    func buildFlatMessages(history: [LLMMessage]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        let sys = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        for m in history {
            let text = flattenToText(m.content)
            guard !text.isEmpty else { continue }
            messages.append(["role": m.role.rawValue, "content": text])
        }
        return messages
    }

    /// Tool-aware path: emit Ollama's native shape, which differs
    /// from OpenAI in two small ways the dispatcher already
    /// abstracts over:
    ///   * `arguments` is a parsed object, not a JSON-encoded string.
    ///   * Tool calls and tool results have no `tool_call_id`; Ollama
    ///     pairs them by order of appearance in the messages array.
    /// We preserve insertion order so that's safe.
    func buildStructuredMessages(history: [LLMMessage]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        let sys = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        for m in history {
            switch m.role {
            case .user:
                var textParts: [String] = []
                var toolMessages: [[String: Any]] = []
                for c in m.content {
                    switch c {
                    case .text(let t):
                        if !t.isEmpty { textParts.append(t) }
                    case .toolResult(_, let content, _):
                        toolMessages.append([
                            "role":    "tool",
                            "content": content
                        ])
                    case .toolUse:
                        // Doesn't belong in a user message; round-trip
                        // as descriptive text rather than dropping it.
                        textParts.append(flattenToText([c]))
                    }
                }
                if !textParts.isEmpty {
                    messages.append([
                        "role":    "user",
                        "content": textParts.joined(separator: "\n")
                    ])
                }
                messages.append(contentsOf: toolMessages)

            case .assistant:
                var textParts: [String] = []
                var toolCalls: [[String: Any]] = []
                for c in m.content {
                    switch c {
                    case .text(let t):
                        if !t.isEmpty { textParts.append(t) }
                    case .toolUse(_, let name, let input):
                        toolCalls.append([
                            "function": [
                                "name":      name,
                                "arguments": input
                            ] as [String: Any]
                        ])
                    case .toolResult:
                        break
                    }
                }
                guard !textParts.isEmpty || !toolCalls.isEmpty else { continue }
                var msg: [String: Any] = [
                    "role":    "assistant",
                    "content": textParts.joined(separator: "\n")
                ]
                if !toolCalls.isEmpty {
                    msg["tool_calls"] = toolCalls
                }
                messages.append(msg)
            }
        }
        return messages
    }
}

/// Collapse a `[LLMContent]` to plain text for backends that don't yet
/// handle tool blocks. Preserves enough signal that the assistant can see
/// what tool calls / results appeared earlier in the conversation.
private func flattenToText(_ blocks: [LLMContent]) -> String {
    var out: [String] = []
    for block in blocks {
        switch block {
        case .text(let t):
            out.append(t)
        case .toolUse(_, let name, let input):
            out.append("[assistant requested tool: \(name) input=\(input)]")
        case .toolResult(_, let result, let isError):
            out.append(isError
                ? "[tool error: \(result)]"
                : "[tool result: \(result)]")
        }
    }
    return out.joined(separator: "\n")
}

// MARK: - Shared helpers

private func sendRequest(_ req: URLRequest) async throws -> (Data, URLResponse) {
    do {
        return try await URLSession.shared.data(for: req)
    } catch {
        throw LLMError.transport(error.localizedDescription)
    }
}

func ensureOK(_ resp: URLResponse, data: Data) throws {
    guard let http = resp as? HTTPURLResponse else { return }
    if (200..<300).contains(http.statusCode) { return }
    let snippet = String(data: data, encoding: .utf8).map {
        $0.count > 500 ? String($0.prefix(500)) + "…" : $0
    } ?? "<non-utf8 body>"
    throw LLMError.http(http.statusCode, snippet)
}

// MARK: - Keychain (API key storage)

enum LLMKeychain {
    private static let service = "com.bnetgui.ai"

    static func save(_ value: String, for provider: LLMProvider) {
        let account = provider.rawValue
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        guard !value.isEmpty else { return }

        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(for provider: LLMProvider) -> String {
        let account = provider.rawValue
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }
}
