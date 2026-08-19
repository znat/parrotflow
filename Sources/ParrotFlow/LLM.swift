import Foundation

/// One call, whichever protocol the model on the other end speaks.
///
/// Three envelopes and no more: everything past Ollama, OpenAI and Anthropic
/// speaks one of the three. What differs between providers inside a protocol —
/// which field carries the token budget, whether temperature is allowed at all
/// — is settled here per api, and `params:` is what reaches anything this file
/// has not heard of.
///
/// Every failure is thrown rather than swallowed. The pipeline turns a throw
/// back into the transcript untouched, which is the rule a cloud model must
/// obey as strictly as a local one: a rewrite is worth less than a sentence.
enum LLM {

    enum Failure: LocalizedError {
        case noKey(ModelSpec)
        case unreachable(ModelSpec)
        case badStatus(ModelSpec, Int, String)
        case emptyResponse(ModelSpec)

        var errorDescription: String? {
            switch self {
            case .noKey(let model):
                return "\(model.name): no API key — \(model.key.described)."
            case .unreachable(let model):
                return "Can't reach \(model.name) at \(model.url)."
            case .badStatus(let model, let code, let detail):
                let said = detail.isEmpty ? "" : " — \(detail)"
                return "\(model.name) returned HTTP \(code)\(said)."
            case .emptyResponse(let model):
                return "\(model.name) returned nothing."
            }
        }
    }

    /// One-shot completion. `json` asks for valid JSON where the protocol has a
    /// way to ask; `maxTokens` is the caller's budget, which a model's own
    /// `max_tokens:` replaces.
    static func complete(
        system: String,
        user: String,
        json: Bool,
        maxTokens: Int = 32,
        config: ModelSpec
    ) async throws -> String {
        let budget = config.maxTokens ?? maxTokens
        switch config.api {
        case .ollama:
            return try await LocalLLM.complete(
                system: system, user: user, json: json, maxTokens: budget, config: config
            )
        case .openai:
            return try await openAI(
                system: system, user: user, json: json, maxTokens: budget, config: config
            )
        case .anthropic:
            return try await anthropic(
                system: system, user: user, maxTokens: budget, config: config
            )
        }
    }

    /// Whether this model is worth offering — greys a menu out rather than
    /// letting it fail at the moment of use.
    ///
    /// Only the local one is asked over the network. A cloud model is "there"
    /// when a key is, because the alternative is a billed request every time a
    /// menu opens, and a 401 is not something a menu can tell you anyway.
    static func available(config: ModelSpec) async -> Bool {
        switch config.api {
        case .ollama: return await LocalLLM.isAvailable(config: config)
        case .openai, .anthropic: return config.key.resolve() != nil
        }
    }

    // MARK: - OpenAI

    /// Anything speaking the OpenAI chat API: OpenAI itself, and the providers
    /// that copied it.
    ///
    /// `max_completion_tokens`, not `max_tokens`: the reasoning models only
    /// accept the newer name. A server that only knows the old one is a
    /// `params: { max_tokens: N }` away, which drops ours — see `body`.
    ///
    /// No temperature unless the config asked for one. The GPT-5 family rejects
    /// it outright, and a rejected request is a lost sentence.
    private static func openAI(
        system: String, user: String, json: Bool, maxTokens: Int, config: ModelSpec
    ) async throws -> String {
        guard let key = config.key.resolve() else { throw Failure.noKey(config) }
        guard let url = URL(string: "\(config.url)/chat/completions") else {
            throw Failure.unreachable(config)
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "max_completion_tokens": maxTokens,
            // none | minimal | low | medium | high. `off` is `none` rather than
            // an omitted field: GPT-5.1 and later default to reasoning, and a
            // one-line rewrite that thinks first costs seconds nobody asked for.
            "reasoning_effort": config.reasoning == .off ? "none" : config.reasoning.rawValue,
        ]
        if let temperature = config.temperature { body["temperature"] = temperature }
        if json { body["response_format"] = ["type": "json_object"] }
        // An older server wants `max_tokens`. Sending both is a 400 on the
        // strict ones, so naming it in `params:` takes ours out.
        if config.params["max_tokens"] != nil { body.removeValue(forKey: "max_completion_tokens") }
        merge(config.params, into: &body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = config.timeout

        let data = try await send(request, config: config)
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String
        else { throw Failure.emptyResponse(config) }

        // `reasoning_content` sits beside `content` on the reasoning models of
        // several providers and is never read here. What still has to be taken
        // out is thinking a server inlines into the answer — a `<think>` block
        // pasted into your document is what happens otherwise.
        let answer = stripThinking(text)
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyResponse(config)
        }
        return answer
    }

    // MARK: - Anthropic

    /// The Messages API.
    ///
    /// `max_tokens` is required, and thinking tokens count against it — so a
    /// caller's 32-token budget would truncate the answer before it started.
    /// A rung above `off` therefore raises the floor.
    ///
    /// No `budget_tokens`: the current models reject it. Depth is
    /// `output_config.effort` next to adaptive thinking, and `off` is thinking
    /// turned off outright.
    private static func anthropic(
        system: String, user: String, maxTokens: Int, config: ModelSpec
    ) async throws -> String {
        guard let key = config.key.resolve() else { throw Failure.noKey(config) }
        guard let url = URL(string: "\(config.url)/v1/messages") else {
            throw Failure.unreachable(config)
        }

        let thinking = config.reasoning != .off
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": thinking ? max(maxTokens, 4096) : maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        if thinking {
            body["thinking"] = ["type": "adaptive"]
            // The API's ladder starts at low; `minimal` is this app's rung, not
            // one it has.
            body["output_config"] = ["effort": config.reasoning == .minimal
                ? "low" : config.reasoning.rawValue]
        } else {
            body["thinking"] = ["type": "disabled"]
        }
        // Same reason as the OpenAI envelope: current models refuse it, so it
        // goes only when the config insisted.
        if let temperature = config.temperature { body["temperature"] = temperature }
        merge(config.params, into: &body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = config.timeout

        let data = try await send(request, config: config)
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = object["content"] as? [[String: Any]]
        else { throw Failure.emptyResponse(config) }

        // Text blocks only. A thinking block is in the same array, and pasting
        // one into your document is the failure this exists to prevent.
        let answer = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw Failure.emptyResponse(config) }
        return answer
    }

    // MARK: - Shared

    /// `params:` over whatever the envelope built. A `null` deletes the key
    /// rather than sending one — see `ModelParam`.
    static func merge(_ params: [String: ModelParam], into body: inout [String: Any]) {
        for (name, value) in params {
            if case .null = value {
                body.removeValue(forKey: name)
            } else {
                body[name] = value.json
            }
        }
    }

    private static func send(_ request: URLRequest, config: ModelSpec) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable(config)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable(config) }
        guard http.statusCode == 200 else {
            throw Failure.badStatus(config, http.statusCode, message(in: data))
        }
        return data
    }

    /// The provider's own words for what was wrong, when it wrote any. Both
    /// protocols nest it under `error.message`, and it is the difference
    /// between "HTTP 400" and "unsupported value: temperature".
    private static func message(in data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let said = error["message"] as? String
        else { return "" }
        return said.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a `<think>` block a server left in the answer.
    ///
    /// Not every OpenAI-compatible server keeps reasoning out of `content`.
    /// Ollama's own compatibility layer is one that does not, depending on the
    /// model, and the result reads as the model rambling rather than as a
    /// protocol difference.
    static func stripThinking(_ raw: String) -> String {
        guard raw.contains("<think>") || raw.contains("</think>") else { return raw }
        var text = raw
        if let close = text.range(of: "</think>", options: .backwards) {
            text = String(text[close.upperBound...])
        } else if let open = text.range(of: "<think>") {
            // Opened and never closed: the answer was cut off inside the
            // thinking, so there is nothing to keep.
            text = String(text[..<open.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
