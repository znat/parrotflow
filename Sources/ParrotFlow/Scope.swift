import Foundation

/// What a pipeline knows about the transcript in flight, beyond the transcript.
///
/// Every stage used to be `String -> String`, which meant the only thing one
/// stage could tell the next was the sentence itself. A condition could ask
/// "does the text still say `function`" and nothing else — so a stage that had
/// already done the work had no way to say so, and the stage after it re-derived
/// the same judgement from the same words, or ran when it should not have.
///
/// A scope is the other channel. A stage contributes facts about *what it did*;
/// later conditions read them. The rules are deliberately narrow, because the
/// failure this design invites is a variable that outlives the text it described:
///
///   - A stage writes only under its **own name**. The namespace is supplied by
///     the runner, never by the stage, so one stage cannot reach into another's
///     facts by accident or on purpose. Cross-namespace clobbering is not
///     guarded against here; it is unrepresentable.
///   - Everything else **carries through untouched**. A stage contributing
///     nothing erases nothing — carrying is the loop's job, not a courtesy each
///     script has to remember. A `sed` one-liner cannot echo a namespace, and a
///     contract only some stages can honour is not a contract.
///   - A name is a fact about the stage, not a claim about the text.
///     `code_identifiers.count` stays true after a later stage rewrites the
///     sentence; `has_identifier` would not. The namespace makes the first
///     reading the natural one, which is the whole reason facts are filed under
///     the stage that produced them rather than merged flat.
struct Scope: Equatable {

    /// One value a condition can read.
    ///
    /// Scalars only, and four of them. The ceiling is not shyness: the predicate
    /// language that reads these has to be implementable twice — once here, once
    /// wherever a pipeline runner is written next — and every type added to this
    /// enum is a comparison, a coercion and a parse rule in both. Four scalars
    /// and one level of namespace is the largest domain that stays a few hundred
    /// lines rather than a type system.
    enum Value: Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)

        /// How it reads in a log line or a `--pipeline` listing.
        var described: String {
            switch self {
            case .string(let s): return "\"\(s)\""
            case .int(let i): return String(i)
            case .double(let d): return String(d)
            case .bool(let b): return b ? "true" : "false"
            }
        }

        /// The number this is, for `<`, `>` and friends. Ints and doubles
        /// compare with each other — a script that returns `1` and one that
        /// returns `1.0` have said the same thing, and a condition that treats
        /// them differently would be reporting the script's JSON encoder rather
        /// than its answer.
        var asDouble: Double? {
            switch self {
            case .int(let i): return Double(i)
            case .double(let d): return d
            default: return nil
            }
        }
    }

    /// Keyed by the whole dotted path — `numbers.count`, `asr.confidence`,
    /// `text`. Flat storage rather than nested dictionaries because every
    /// question asked of it is "what is at this path", and one level of nesting
    /// would be a tree walk to answer a lookup.
    private(set) var values: [String: Value] = [:]

    /// The namespaces a stage may not be filed under, because something else is
    /// already there. A transform called `asr` would put `asr.confidence` in
    /// reach of two writers and leave no way to tell which one a condition read.
    ///
    /// `text` is here because it is a bare name rather than a namespace: a
    /// stage called `text` would contribute `text.count` while `text` itself is
    /// a string, and a path that is both a value and a prefix has no sensible
    /// answer.
    static let reserved: Set<String> = [
        "text", "app", "bundle_id", "language", "asr", "vad",
    ]

    init(values: [String: Value] = [:]) {
        self.values = values
    }

    subscript(path: String) -> Value? { values[path] }

    /// Set a bare, un-namespaced name — the seeds the runner puts in before any
    /// stage runs, and `text`, which it rewrites after each one.
    mutating func set(_ name: String, _ value: Value) {
        values[name] = value
    }

    mutating func set(_ name: String, _ value: Value?) {
        guard let value else { return }
        values[name] = value
    }

    /// File a stage's contribution under its own name.
    ///
    /// Keys already present under this namespace are replaced and keys under
    /// every other namespace are left alone — which is the whole of "carry
    /// through unless overridden", enforced in the one place that knows both
    /// halves.
    ///
    /// A stage that appears twice in a pipeline writes the same namespace twice,
    /// and the second run wins. That is the reading a person expects from a list
    /// executed top to bottom, and the alternative — refusing the pipeline —
    /// would rule out running `replacements` before and after a rewrite, which
    /// is a thing people legitimately do. A condition between the two sees the
    /// first run's facts; one after them sees the second's.
    mutating func merge(_ contribution: [String: Value], under namespace: String) {
        for (key, value) in contribution {
            values["\(namespace).\(key)"] = value
        }
    }

    /// Everything filed under one namespace, with the prefix taken back off.
    /// For printing a stage's contribution, which is a question about one stage
    /// rather than about the scope.
    func namespace(_ name: String) -> [String: Value] {
        let prefix = name + "."
        var found: [String: Value] = [:]
        for (path, value) in values where path.hasPrefix(prefix) {
            found[String(path.dropFirst(prefix.count))] = value
        }
        return found
    }

    /// Every path, sorted, for a deterministic listing. `--pipeline` prints
    /// these and a case set compares them, and a dictionary's own order is
    /// neither stable nor meaningful.
    var paths: [String] { values.keys.sorted() }
}

/// What a stage hands back.
///
/// The asymmetry with what a stage is *given* is deliberate and is the reason
/// carry-through cannot be forgotten. A stage receives the whole scope and
/// returns only its own contribution: it has no way to express "and here is
/// everything else, unchanged", so it has no way to get that wrong. The runner,
/// which is the only thing holding the accumulated scope, is the only thing that
/// can drop a namespace — and it never does.
struct StageResult: Equatable {
    var text: String
    var vars: [String: Scope.Value] = [:]

    init(text: String, vars: [String: Scope.Value] = [:]) {
        self.text = text
        self.vars = vars
    }
}

// MARK: - JSON

/// Decoded straight from a script's stdout, and encoded into the context a
/// script is given. Kept next to the type rather than in `CommandRunner` because
/// the shape is the interface: a body written in any language is conforming
/// exactly when it round-trips through this.
extension Scope.Value: Codable {

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool first. `JSONDecoder` will decode `true` as an `Int` 1 on some
        // platforms if asked in the wrong order, and a script that returned a
        // flag would find its condition comparing numbers.
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let i = try? container.decode(Int.self) { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "a variable must be a string, number or boolean"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        }
    }
}
