import Foundation

/// One model this config can reach, resolved and ready to call.
///
/// `api` is the wire protocol, not the vendor. Three exist and everyone else
/// speaks one of them, so a provider ParrotFlow has never heard of is an
/// `endpoint:` away rather than an adapter away.
///
/// The knobs below are the ones every protocol has some answer for. Anything
/// else goes in `params`, which is merged into the request body untouched —
/// see there.
struct ModelSpec: Equatable {
    enum API: String, Equatable, CaseIterable {
        case ollama, openai, anthropic

        var defaultEndpoint: String {
            switch self {
            case .ollama: return "http://localhost:11434"
            case .openai: return "https://api.openai.com/v1"
            case .anthropic: return "https://api.anthropic.com"
            }
        }

        /// Whether a call leaves this Mac. `--check-config` says so out loud:
        /// naming a model on a transform is what sends your dictation to
        /// somebody else's server, and it is one word in a config file.
        var isLocal: Bool { self == .ollama }
    }

    /// How hard the model may think, in five rungs that mean the same thing on
    /// every protocol.
    ///
    /// A ladder rather than a passthrough. Each envelope maps it to whatever
    /// its provider actually has — `think:`, `reasoning_effort`, adaptive
    /// thinking plus an effort — and a provider with no such knob sends
    /// nothing. `params:` overrides the result where a model wants a rung this
    /// does not have.
    enum Reasoning: String, Equatable, CaseIterable {
        case off, minimal, low, medium, high
    }

    /// The name it was given in `models:`, for logs and `--check-config`.
    var name: String = "local"
    var api: API = .ollama
    var model: String = ""
    /// Empty means `api.defaultEndpoint`.
    var endpoint: String = ""
    var key: KeySource = KeySource()
    var reasoning: Reasoning = .off
    /// Nil means the envelope's own default — which for a cloud model is to
    /// send no temperature at all, because reasoning models reject it.
    var temperature: Double?
    /// Replaces the budget the caller worked out. Nil leaves it alone — which
    /// is usually right, since a prompt that rewrites a paragraph and one that
    /// answers with a single word already ask for different numbers.
    var maxTokens: Int?
    var timeout: TimeInterval = 20
    /// Ollama only — see `LocalLLM.pinned`. Ignored by every other api.
    var keepLoaded: Bool = true
    /// The model everything falls back to when nothing names one.
    ///
    /// Written on the model rather than as a name somewhere else, so the entry
    /// says what it is instead of a second place repeating its key. With one
    /// model configured it is the default whether or not it says so; with
    /// several, exactly one must claim it, and `--check-config` refuses both
    /// none and more than one — see `Config.modelProblems`.
    var isDefault: Bool = false
    /// Merged into the request body last, unvalidated.
    ///
    /// The escape hatch that makes a provider this app has never been run
    /// against usable without a release: `params: { top_k: 40 }`. A key here
    /// replaces whatever the envelope computed under the same name.
    var params: [String: ModelParam] = [:]
    /// What this entry said that could not be read, in words. The value is
    /// ignored and the default stands; `--check-config` prints these.
    var refused: [String] = []

    /// The endpoint with no trailing slash, so paths can be appended.
    var url: String {
        let written = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = written.isEmpty ? api.defaultEndpoint : written
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    /// Just the host, for a line with room for one thing — `api.openai.com`.
    var host: String { URL(string: url)?.host ?? url }

    /// How it reads in a log line or a check: `gpt (openai, gpt-5.6-luna, reasoning low)`.
    var described: String {
        "\(name) (\(api.rawValue), \(model.isEmpty ? "no model" : model),"
            + " reasoning \(reasoning.rawValue))"
    }

    /// The same spec with a call site's overrides applied — see `ModelRef`.
    func applying(_ ref: ModelRef?) -> ModelSpec {
        guard let ref else { return self }
        var out = self
        if let value = ref.reasoning { out.reasoning = value }
        if let value = ref.temperature { out.temperature = value }
        if let value = ref.maxTokens { out.maxTokens = value }
        if let value = ref.timeout { out.timeout = value }
        out.params.merge(ref.params) { _, new in new }
        return out
    }
}

// MARK: - Where a key comes from

/// A reference to an API key, rather than a key.
///
/// `config.yaml` is a plain file that people paste to each other, so the
/// supported forms name somewhere else to look. A literal key still works —
/// refusing it would only move it into a shell history — and is announced by
/// `--check-config` every time.
///
/// `env:` is right for the CLI and useless in the app: ParrotFlow launches
/// from Finder, which hands it none of your shell's environment. `file:` is
/// the one that works in both.
///
/// `keychain` is the default for a cloud model that names no key at all, so
/// the common case is nothing in the file and nothing on disk. See `Keychain`.
struct KeySource: Equatable {
    enum Kind: Equatable { case absent, environment, file, literal, keychain }

    var kind: Kind = .absent
    /// The variable name, the path, the keychain account, or the key itself.
    var value: String = ""

    init() {}

    init(written raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text == "keychain" {
            kind = .keychain
            // Filled in with the model's own name once it has one — a spec
            // cannot see the key it was written under. See `adopt(account:)`.
            value = ""
        } else if text.hasPrefix("env:") {
            kind = .environment
            value = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        } else if text.hasPrefix("file:") {
            kind = .file
            value = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else {
            kind = .literal
            value = text
        }
    }

    var isSet: Bool { kind == .keychain || (kind != .absent && !value.isEmpty) }

    /// Give this source the model's name, which is the account it reads.
    ///
    /// Two things happen here, both needing a name the spec did not have while
    /// it was being decoded: an explicit `api_key: keychain` learns its
    /// account, and a cloud model that named no key at all becomes a keychain
    /// one. An `ollama` entry is left alone — it needs no key, and turning its
    /// silence into a keychain lookup would report a missing key for a model
    /// that never wanted one.
    mutating func adopt(account: String, api: ModelSpec.API) {
        if kind == .keychain, value.isEmpty { value = account }
        if kind == .absent, !api.isLocal {
            kind = .keychain
            value = account
        }
    }

    /// The key, or nil when the place it names holds nothing.
    func resolve() -> String? {
        switch kind {
        case .absent:
            return nil
        case .literal:
            return value.isEmpty ? nil : value
        case .environment:
            let found = ProcessInfo.processInfo.environment[value]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (found?.isEmpty == false) ? found : nil
        case .keychain:
            return Keychain.read(value)
        case .file:
            let path = (value as NSString).expandingTildeInPath
            let found = try? String(contentsOfFile: path, encoding: .utf8)
            let key = found?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (key?.isEmpty == false) ? key : nil
        }
    }

    /// Where the key comes from and whether it is there — never the key.
    var described: String {
        switch kind {
        case .absent:
            return "no api_key"
        case .literal:
            return "a key written into config.yaml"
        case .environment:
            return "$\(value)" + (resolve() == nil ? " (not set)" : "")
        case .keychain:
            return "the Keychain" + (resolve() == nil ? " (no key yet)" : "")
        case .file:
            return value + (resolve() == nil ? " (unreadable or empty)" : "")
        }
    }
}

// MARK: - What a call site may change

/// A transform naming a model, and what it changes about it.
///
/// Written as a scalar when it only picks one — `model: gpt` — or as a mapping
/// when it also changes a setting. Only call-site settings may be changed:
/// `api`, `endpoint`, `model` and `api_key` describe a connection, and a
/// different connection is a different entry in `models:` rather than an
/// override buried in a transform.
struct ModelRef: Equatable, Decodable {
    /// The name in `models:`. Empty means "the default model, with these
    /// settings changed".
    var use: String = ""
    var reasoning: ModelSpec.Reasoning?
    var temperature: Double?
    var maxTokens: Int?
    var timeout: Double?
    var params: [String: ModelParam] = [:]
    /// What was written here that only a `models:` entry may say, in words.
    /// Reported by `--check-config`; the key itself is ignored.
    var rejected: [String] = []

    enum CodingKeys: String, CodingKey {
        case use, reasoning, temperature, params
        case maxTokens = "max_tokens"
        case timeout = "timeout_seconds"
        case api, endpoint, model
        case apiKey = "api_key"
    }

    init() {}

    init(from decoder: Decoder) throws {
        if let scalar = try? decoder.singleValueContainer().decode(String.self) {
            use = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        use = (try c.decodeIfPresent(String.self, forKey: .use) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Read as a string and mapped by hand: an unknown rung is reported and
        // ignored rather than throwing, so one mistyped word cannot take the
        // whole config with it.
        if let written = try c.decodeIfPresent(String.self, forKey: .reasoning) {
            if let rung = ModelSpec.Reasoning(rawValue: written.lowercased()) {
                reasoning = rung
            } else {
                rejected.append("reasoning: \(written) — have: "
                    + ModelSpec.Reasoning.allCases.map(\.rawValue).joined(separator: ", "))
            }
        }
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout)
        params = try c.decodeIfPresent([String: ModelParam].self, forKey: .params) ?? [:]

        for key in [CodingKeys.api, .endpoint, .model, .apiKey] {
            guard c.contains(key) else { continue }
            rejected.append("`\(key.stringValue):` describes a connection —"
                + " put it in `models:` and name it with `use:`")
        }
    }
}

// MARK: - Anything a request body can carry

/// A value written under `params:`, on its way into JSON.
///
/// `null` is not a value but a deletion: it takes the key out of the body
/// instead of sending it. That is how a server that refuses a field this app
/// sends by default — `reasoning_effort` on a model that does not reason — is
/// dealt with in the config rather than in a release.
enum ModelParam: Equatable {
    case null
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case list([ModelParam])
    case map([String: ModelParam])

    var json: Any {
        switch self {
        case .null: return NSNull()
        case .string(let value): return value
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .list(let values): return values.map(\.json)
        case .map(let values): return values.mapValues(\.json)
        }
    }
}

extension ModelParam: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool before Int, or YAML's `true` arrives as a number on some
        // decoders. Int before Double, so `40` is not sent as `40.0`.
        if let value = try? c.decode(Bool.self) { self = .bool(value); return }
        if let value = try? c.decode(Int.self) { self = .int(value); return }
        if let value = try? c.decode(Double.self) { self = .double(value); return }
        if let value = try? c.decode(String.self) { self = .string(value); return }
        if let value = try? c.decode([ModelParam].self) { self = .list(value); return }
        if let value = try? c.decode([String: ModelParam].self) { self = .map(value); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "not a value a request body can carry"
        )
    }
}

// MARK: - Reading one out of config.yaml

extension ModelSpec: Decodable {
    enum CodingKeys: String, CodingKey {
        case api, model, endpoint, reasoning, temperature, params
        case apiKey = "api_key"
        case maxTokens = "max_tokens"
        case timeoutSeconds = "timeout_seconds"
        case keepLoaded = "keep_loaded"
        case isDefault = "default"
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let written = try c.decodeIfPresent(String.self, forKey: .api) {
            let name = written.trimmingCharacters(in: .whitespaces).lowercased()
            if let known = API(rawValue: name) {
                api = known
            } else {
                refused.append("api: \(written) — have: "
                    + API.allCases.map(\.rawValue).joined(separator: ", "))
            }
        }
        model = (try c.decodeIfPresent(String.self, forKey: .model) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint = (try c.decodeIfPresent(String.self, forKey: .endpoint) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let written = try c.decodeIfPresent(String.self, forKey: .apiKey) {
            key = KeySource(written: written)
        }
        if let written = try c.decodeIfPresent(String.self, forKey: .reasoning) {
            if let rung = Reasoning(rawValue: written.trimmingCharacters(in: .whitespaces).lowercased()) {
                reasoning = rung
            } else {
                refused.append("reasoning: \(written) — have: "
                    + Reasoning.allCases.map(\.rawValue).joined(separator: ", "))
            }
        }
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        if let value = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) {
            timeout = value
        }
        if let value = try c.decodeIfPresent(Bool.self, forKey: .keepLoaded) {
            keepLoaded = value
        }
        if let value = try c.decodeIfPresent(Bool.self, forKey: .isDefault) {
            isDefault = value
        }
        params = try c.decodeIfPresent([String: ModelParam].self, forKey: .params) ?? [:]
    }
}
