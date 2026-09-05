import Foundation

// MARK: - Streaming protocol
//
// Streaming variants of the LLM clients in LLMBackend.swift. Each one
// builds the same request as its non-streaming `send`, sets the
// provider's stream flag, and parses the incremental wire format
// (Anthropic SSE, OpenAI-compatible SSE, Ollama NDJSON) into the same
// `[LLMContent]` the agentic loop already understands, while pushing
// text deltas to the UI as they arrive.

/// Delta callback: awaited on the main actor so deltas arrive in order.
typealias LLMTextDeltaHandler = @MainActor @Sendable (String) -> Void

protocol LLMStreamingClient: LLMClient {
    /// Like `send(history:tools:)` but calls `onTextDelta` for every
    /// text fragment as it streams in. The returned blocks are the
    /// complete response (text plus any tool-use blocks).
    func sendStreaming(
        history: [LLMMessage],
        tools: [LLMTool],
        onTextDelta: @escaping LLMTextDeltaHandler
    ) async throws -> [LLMContent]
}

// MARK: - Shared helpers

private func openStream(_ req: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
    do {
        return try await URLSession.shared.bytes(for: req)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        if (error as? URLError)?.code == .cancelled { throw CancellationError() }
        throw LLMError.transport(error.localizedDescription)
    }
}

/// Reads the (small) error body of a non-2xx streaming response so the
/// user sees the provider's message rather than a bare status code.
private func ensureStreamOK(_ resp: URLResponse, bytes: URLSession.AsyncBytes) async throws {
    guard let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
    var data = Data()
    for try await b in bytes {
        data.append(b)
        if data.count > 4096 { break }
    }
    try ensureOK(resp, data: data)
}

private func jsonObject(_ line: Substring) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// Accumulates streamed tool-call fragments keyed by block index.
private struct ToolAccumulator {
    var id: String
    var name: String
    var argumentsJSON: String = ""

    func content() -> LLMContent {
        let data = argumentsJSON.data(using: .utf8) ?? Data("{}".utf8)
        let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return .toolUse(id: id, name: name, input: input)
    }
}

// MARK: - Anthropic (Messages API, server-sent events)

extension AnthropicClient: LLMStreamingClient {
    func sendStreaming(
        history: [LLMMessage],
        tools: [LLMTool],
        onTextDelta: @escaping LLMTextDeltaHandler
    ) async throws -> [LLMContent] {
        guard var url = URL(string: config.baseURL) else {
            throw LLMError.notConfigured("Invalid base URL.")
        }
        url.append(path: "/v1/messages")

        let messages: [[String: Any]] = history.map { msg in
            let blocks: [[String: Any]] = msg.content.map { block in
                switch block {
                case .text(let t):
                    return ["type": "text", "text": t]
                case .toolUse(let id, let name, let input):
                    return ["type": "tool_use", "id": id, "name": name, "input": input]
                case .toolResult(let id, let result, let isError):
                    var b: [String: Any] = [
                        "type": "tool_result", "tool_use_id": id, "content": result
                    ]
                    if isError { b["is_error"] = true }
                    return b
                }
            }
            return ["role": msg.role.rawValue, "content": blocks]
        }

        var body: [String: Any] = [
            "model":       config.model,
            "max_tokens":  config.maxTokens,
            "temperature": config.temperature,
            "messages":    messages,
            "stream":      true
        ]
        let sys = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { body["system"] = sys }
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                ["name": t.name, "description": t.description, "input_schema": t.inputSchema] as [String: Any]
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await openStream(req)
        try await ensureStreamOK(resp, bytes: bytes)

        var texts: [Int: String] = [:]
        var toolBlocks: [Int: ToolAccumulator] = [:]
        var order: [Int] = []

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let obj = jsonObject(Substring(payload)) else { continue }
            switch obj["type"] as? String {
            case "content_block_start":
                let index = obj["index"] as? Int ?? order.count
                order.append(index)
                if let block = obj["content_block"] as? [String: Any] {
                    if block["type"] as? String == "tool_use" {
                        toolBlocks[index] = ToolAccumulator(
                            id: block["id"] as? String ?? UUID().uuidString,
                            name: block["name"] as? String ?? ""
                        )
                    } else {
                        let initial = block["text"] as? String ?? ""
                        texts[index] = initial
                        if !initial.isEmpty { await onTextDelta(initial) }
                    }
                }
            case "content_block_delta":
                let index = obj["index"] as? Int ?? 0
                guard let delta = obj["delta"] as? [String: Any] else { continue }
                if let t = delta["text"] as? String {
                    texts[index, default: ""] += t
                    await onTextDelta(t)
                } else if let partial = delta["partial_json"] as? String {
                    toolBlocks[index]?.argumentsJSON += partial
                }
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "Unknown streaming error."
                throw LLMError.http(0, msg)
            case "message_stop":
                break
            default:
                continue
            }
        }

        var out: [LLMContent] = []
        for index in order {
            if let t = texts[index], !t.isEmpty { out.append(.text(t)) }
            if let tool = toolBlocks[index] { out.append(tool.content()) }
        }
        if out.isEmpty {
            throw LLMError.decoding("Anthropic stream ended without any content blocks.")
        }
        return out
    }
}

// MARK: - OpenAI / LM Studio (Chat Completions, server-sent events)

extension OpenAIClient: LLMStreamingClient {
    func sendStreaming(
        history: [LLMMessage],
        tools: [LLMTool],
        onTextDelta: @escaping LLMTextDeltaHandler
    ) async throws -> [LLMContent] {
        guard var url = URL(string: config.baseURL) else {
            throw LLMError.notConfigured("Invalid base URL.")
        }
        url.append(path: "/chat/completions")

        let messages = tools.isEmpty
            ? buildFlatMessages(history: history)
            : buildStructuredMessages(history: history)

        var body: [String: Any] = [
            "model":       config.model,
            "messages":    messages,
            "max_tokens":  config.maxTokens,
            "temperature": config.temperature,
            "stream":      true
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                [
                    "type": "function",
                    "function": [
                        "name": t.name, "description": t.description, "parameters": t.inputSchema
                    ] as [String: Any]
                ] as [String: Any]
            }
            body["tool_choice"] = "auto"
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await openStream(req)
        try await ensureStreamOK(resp, bytes: bytes)

        var text = ""
        var toolCalls: [Int: ToolAccumulator] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = jsonObject(Substring(payload)),
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any] else { continue }
            if let t = delta["content"] as? String, !t.isEmpty {
                text += t
                await onTextDelta(t)
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for tc in calls {
                    let index = tc["index"] as? Int ?? 0
                    let function = tc["function"] as? [String: Any] ?? [:]
                    if toolCalls[index] == nil {
                        toolCalls[index] = ToolAccumulator(
                            id: tc["id"] as? String ?? "call-\(UUID().uuidString)",
                            name: function["name"] as? String ?? ""
                        )
                    } else if let name = function["name"] as? String, !name.isEmpty {
                        toolCalls[index]?.name += name
                    }
                    if let args = function["arguments"] as? String {
                        toolCalls[index]?.argumentsJSON += args
                    }
                }
            }
        }

        var out: [LLMContent] = []
        if !text.isEmpty { out.append(.text(text)) }
        for index in toolCalls.keys.sorted() {
            if let tool = toolCalls[index] { out.append(tool.content()) }
        }
        if out.isEmpty {
            throw LLMError.decoding("Stream ended with neither `content` nor `tool_calls`.")
        }
        return out
    }
}

// MARK: - Ollama (newline-delimited JSON)

extension OllamaClient: LLMStreamingClient {
    func sendStreaming(
        history: [LLMMessage],
        tools: [LLMTool],
        onTextDelta: @escaping LLMTextDeltaHandler
    ) async throws -> [LLMContent] {
        guard var url = URL(string: config.baseURL) else {
            throw LLMError.notConfigured("Invalid base URL.")
        }
        url.append(path: "/api/chat")

        let messages = tools.isEmpty
            ? buildFlatMessages(history: history)
            : buildStructuredMessages(history: history)

        var body: [String: Any] = [
            "model":    config.model,
            "messages": messages,
            "stream":   true,
            "options":  ["temperature": config.temperature, "num_predict": config.maxTokens]
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                [
                    "type": "function",
                    "function": [
                        "name": t.name, "description": t.description, "parameters": t.inputSchema
                    ] as [String: Any]
                ] as [String: Any]
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await openStream(req)
        try await ensureStreamOK(resp, bytes: bytes)

        var text = ""
        var out: [LLMContent] = []

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let obj = jsonObject(Substring(line)) else { continue }
            if let err = obj["error"] as? String { throw LLMError.http(0, err) }
            guard let message = obj["message"] as? [String: Any] else { continue }
            if let t = message["content"] as? String, !t.isEmpty {
                text += t
                await onTextDelta(t)
            }
            if let calls = message["tool_calls"] as? [[String: Any]] {
                for tc in calls {
                    guard let function = tc["function"] as? [String: Any],
                          let name = function["name"] as? String else { continue }
                    let input = (function["arguments"] as? [String: Any]) ?? [:]
                    out.append(.toolUse(id: "ollama-\(UUID().uuidString)", name: name, input: input))
                }
            }
            if obj["done"] as? Bool == true { break }
        }

        if !text.isEmpty { out.insert(.text(text), at: 0) }
        if out.isEmpty {
            throw LLMError.decoding("Ollama stream ended with neither `content` nor `tool_calls`.")
        }
        return out
    }
}
