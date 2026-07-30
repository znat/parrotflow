import Foundation

/// Talks to a local Ollama server.
///
/// HTTP against localhost rather than an embedded runtime: Ollama is already
/// how most people keep models on a Mac, it handles loading and unloading, and
/// it means ParrotFlow ships no model weights and no inference engine. The
/// cost is a dependency the user installs separately, which is why every LLM
/// feature degrades to "not available" rather than failing.
enum LocalLLM {

    struct Config {
        var endpoint: String
        var model: String
        var timeout: TimeInterval
    }

    enum LLMError: LocalizedError {
        case unreachable
        case badStatus(Int)
        case emptyResponse
        case modelMissing(String)

        var errorDescription: String? {
            switch self {
            case .unreachable:
                return "Can't reach Ollama. Is it running? (`ollama serve`)"
            case .badStatus(let code):
                return "Ollama returned HTTP \(code)."
            case .emptyResponse:
                return "Ollama returned nothing."
            case .modelMissing(let model):
                return "Model \"\(model)\" isn't installed. Run `ollama pull \(model)`."
            }
        }
    }

    /// One-shot completion. `json` asks Ollama to constrain output to valid
    /// JSON, which turns "hope the model formats it right" into a parse.
    static func complete(
        system: String,
        user: String,
        json: Bool,
        config: Config
    ) async throws -> String {
        guard let url = URL(string: "\(config.endpoint)/api/generate") else {
            throw LLMError.unreachable
        }

        var body: [String: Any] = [
            "model": config.model,
            "system": system,
            "prompt": user,
            "stream": false,
            // Deterministic: this is extraction, not writing.
            "options": ["temperature": 0],
        ]
        if json { body["format"] = "json" }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = config.timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.unreachable
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 404 { throw LLMError.modelMissing(config.model) }
            throw LLMError.badStatus(http.statusCode)
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = object["response"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw LLMError.emptyResponse }

        return text
    }

    /// True when the server answers and has the model. Used to grey out
    /// features rather than let them fail at the moment of use.
    static func isAvailable(config: Config) async -> Bool {
        guard let url = URL(string: "\(config.endpoint)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = object["models"] as? [[String: Any]]
        else { return false }

        let names = models.compactMap { $0["name"] as? String }
        // Ollama reports "gemma3:4b"; a config saying "gemma3" should match.
        return names.contains { $0 == config.model || $0.hasPrefix(config.model + ":") }
    }
}

// MARK: - Voice commands

/// Turns what was said after the wake phrase into something to do.
enum VoiceCommand {
    /// Open the correction panel for the current selection.
    case openCorrectionPanel
    /// A spelling rule the model extracted from speech.
    case addRule(heard: String, corrected: String)
    /// Understood as nothing actionable.
    case unrecognised(String)

    /// Everything said after the wake phrase, or nil for plain dictation.
    /// Empty string means the phrase was said on its own.
    ///
    /// Shared by the app and by `--command`; when these were two copies, the
    /// test harness silently exercised different logic from the app.
    static func commandAfterWakePhrase(_ text: String, phrase rawPhrase: String) -> String? {
        let phrase = rawPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return nil }

        func normalise(_ value: String) -> [String] {
            value.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
                .joined()
                .split(separator: " ")
                .map(String.init)
        }

        let phraseWords = normalise(phrase)
        let spokenWords = text.split(separator: " ").map(String.init)
        let normalised = normalise(text)
        guard !phraseWords.isEmpty, !normalised.isEmpty else { return nil }

        // Try a few lengths around the phrase. The wake phrase is the first
        // thing said, which is exactly where audio gets clipped by the engine
        // starting up — so "hey parrot, X" arrives as "parrot, X" or "hey
        // parrots X". Requiring an exact prefix loses all of those.
        // Take the best-scoring length, not the first above threshold: with
        // "hey parrot fix vocabulary", "hey parrot fix" also clears 0.7 and
        // would swallow the "fix".
        var matchedWords: Int?
        var bestScore = 0.7
        for count in 1...min(phraseWords.count + 1, normalised.count) {
            let candidate = normalised.prefix(count).joined(separator: " ")
            let score = similarity(candidate, phrase)
            if score > bestScore {
                bestScore = score
                matchedWords = count
            }
        }

        // Last chance: the distinctive word survived on its own ("parrot"),
        // which is what a clipped "hey" leaves behind.
        if matchedWords == nil, let keyword = phraseWords.last, keyword.count >= 4,
           similarity(normalised[0], keyword) >= 0.8 {
            matchedWords = 1
        }

        guard let matchedWords else { return nil }

        guard spokenWords.count == normalised.count else {
            return normalised.dropFirst(matchedWords).joined(separator: " ")
        }
        return spokenWords.dropFirst(matchedWords)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Phrases handled without troubling the LLM. Cheap, deterministic, and
    /// they work when Ollama isn't running.
    static func local(from command: String) -> VoiceCommand? {
        let normalized = command.lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .trimmingCharacters(in: .whitespaces)

        if normalized.isEmpty { return .openCorrectionPanel }

        let vocabularyPhrases = [
            "fix vocabulary", "update vocabulary", "edit vocabulary",
            "fix the vocabulary", "update the vocabulary",
            "fix vocab", "update vocab", "add word", "add a word",
            "fix spelling", "correct spelling",
        ]
        if vocabularyPhrases.contains(normalized) { return .openCorrectionPanel }
        return nil
    }

    /// Asks the model to pull a spelling rule out of something like
    /// "Tasmin spells T A S M E E N".
    static func interpret(
        command: String,
        lastTranscript: String?,
        config: LocalLLM.Config
    ) async throws -> VoiceCommand {
        let system = """
        You extract one spelling-correction rule from a spoken command. Reply with JSON only.

        Speech recognition misspells names. The user says the WRONG word (as recognition wrote it) and gives the RIGHT
        spelling, usually letter by letter.

        "heard"     = the wrong word, the one to be replaced. If a previous
                      transcript is given, "heard" must be a word from it.
        "corrected" = the right spelling, usually the spelled-out letters joined up

        Examples:
        Command: Tasmin spells T A S M E E N
        {"action":"add_rule","heard":"Tasmin","corrected":"Tasmeen"}

        Command: Mick is spelled M I K
        {"action":"add_rule","heard":"Mick","corrected":"Mik"}

        Command: it's spelled S U P A B A S E not super base
        {"action":"add_rule","heard":"super base","corrected":"Supabase"}

        Command: Versov is actually spelled V E R C E L
        {"action":"add_rule","heard":"Versov","corrected":"Vercel"}

        Command: what time is it
        {"action":"none"}

        Both fields are required when action is add_rule. Never output null.
        Output JSON only.
        """

        var user = "Command: \(command)"
        if let lastTranscript, !lastTranscript.isEmpty {
            user += "\n\nThe transcript just before this, for context: \(lastTranscript)"
        }

        let raw = try await LocalLLM.complete(
            system: system, user: user, json: true, config: config
        )

        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unrecognised(command) }

        guard (object["action"] as? String) == "add_rule",
              let heard = (object["heard"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !heard.isEmpty
        else { return .unrecognised(command) }

        // The word to fix lives in the previous transcript, and we already know
        // the target spelling from the letters — so find it there rather than
        // trusting the model. The command itself is dictated too, so the name
        // gets misrecognised a second time: saying "Tasmine spells T A S M E E N"
        // produced heard="Das mean", a rule matching nothing the user ever says.
        // Matching "Tasmeen" against the last transcript finds "Tasmine".
        //
        // A run of spelled-out letters is unambiguously the target spelling, so
        // take it from the text rather than the model. Without this the model
        // reverses the direction on "X spells Y" phrasing — measured: three of
        // seven cases came back with heard and corrected swapped, or with
        // corrected missing entirely.
        let corrected = spelledOutWord(in: command)
            ?? (object["corrected"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let corrected, !corrected.isEmpty else {
            return .unrecognised(command)
        }

        let resolved = lastTranscript
            .flatMap { closestWord(to: corrected, in: $0) }
            ?? heard
        guard resolved.lowercased() != corrected.lowercased() else {
            return .unrecognised(command)
        }

        return .addRule(heard: resolved, corrected: corrected)
    }

    /// The word in `transcript` most like `target`, or nil if nothing is close.
    ///
    /// Tries one- and two-word windows, since a name can be split ("super base"
    /// for "Supabase"). The threshold is deliberately forgiving — speech
    /// recognition mangles exactly the words people need rules for — but not so
    /// forgiving that an unrelated word wins.
    static func closestWord(to target: String, in transcript: String) -> String? {
        let words = transcript
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        var best: (text: String, score: Double)?
        for size in 1...2 where words.count >= size {
            for start in 0...(words.count - size) {
                let candidate = words[start..<(start + size)].joined(separator: " ")
                let score = similarity(candidate, target)
                if score > (best?.score ?? 0) { best = (candidate, score) }
            }
        }

        guard let best, best.score >= 0.5 else { return nil }
        return best.text
    }

    /// 1 - (edit distance / longer length), case- and space-insensitive.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { !$0.isWhitespace })
        let y = Array(b.lowercased().filter { !$0.isWhitespace })
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y { return 1 }

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = Swift.min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(Swift.max(x.count, y.count))
    }

    /// Finds "T A S M E E N" / "t-a-s-m-e-e-n" and joins it up.
    ///
    /// Three or more single letters separated by spaces, hyphens or full stops.
    /// Nothing else in normal speech looks like that, so a match is reliable.
    static func spelledOutWord(in text: String) -> String? {
        let pattern = "\\b(?:[A-Za-z][\\s\\-.]+){2,}[A-Za-z]\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matched = Range(match.range, in: text) else { return nil }

        let letters = text[matched].filter { $0.isLetter }
        guard letters.count >= 3 else { return nil }
        return letters.prefix(1).uppercased() + letters.dropFirst().lowercased()
    }
}
