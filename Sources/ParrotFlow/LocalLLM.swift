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
        /// Hold the model in Ollama's memory between calls — see `keepAlive`.
        var keepLoaded: Bool = true
    }

    /// Ollama's `keep_alive` value meaning "never unload".
    ///
    /// Its default is 5 minutes, and a call after that pays to read the model
    /// off disk again. Measured on gemma4:e4b from the app's own log: 7–10s for
    /// a correction following a gap of more than five minutes, 1–2s for one
    /// inside it. Every slow correction in a day of use was a reload — none was
    /// slow inference. The cost of pinning is a few GB of resident RAM for as
    /// long as the app runs, which is what `llm.keep_loaded` turns off.
    private static let pinned = -1

    /// When the model last actually ran, for `keepWarm` to measure against.
    ///
    /// Only a completed generation counts. A load-only call leaves the weights
    /// somewhere the next forward pass still has to fetch them from, which is
    /// the whole thing `keepWarm` exists to prevent, so stamping on one would
    /// suppress exactly the ping that was needed.
    private static let clock = NSLock()
    private static var stamp = Date.distantPast

    static var lastCallAt: Date {
        clock.lock()
        defer { clock.unlock() }
        return stamp
    }

    private static func stampCall() {
        clock.lock()
        stamp = Date()
        clock.unlock()
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
    ///
    /// `maxTokens` is a ceiling on the answer, and it is not a detail. It was
    /// fixed at 32 while the only question asked was "which word maps to
    /// which", where it caps rambling for free. A prompt that rewrites a
    /// paragraph needs hundreds, and gets cut off mid-word instead of failing
    /// — which reads as the model being bad rather than as a setting.
    static func complete(
        system: String,
        user: String,
        json: Bool,
        maxTokens: Int = 32,
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
            // gemma4 and friends think by default, which for a one-line answer
            // means ~1000 wasted tokens: measured 98s with it on, 4.5s off.
            "think": false,
            "options": [
                // Deterministic: this is extraction, not writing.
                "temperature": 0,
                "num_predict": maxTokens,
            ],
        ]
        if json { body["format"] = "json" }
        if config.keepLoaded { body["keep_alive"] = pinned }

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

        stampCall()
        return text
    }

    /// Generates a single token, to keep the model's weights where a forward
    /// pass can reach them.
    ///
    /// `keep_alive` already stops Ollama unloading the model, and it is not
    /// enough. Measured on a "hey parrot" that felt slow: the router took 4.01s
    /// against 0.5s warm, and Ollama's own log put 3.59s of it in *prompt eval
    /// of five tokens* — 291 of the 296 were served from its prompt cache, so
    /// there was nothing to compute. 718ms a token against a normal 2ms is not
    /// inference, it is 9.5GB of weights being fetched back on first touch. On
    /// this machine, 19.4GB of 20.5GB swap in use, that is what an idle gap
    /// buys you. A pinned model can be resident and cold at the same time.
    ///
    /// So the ping has to generate, not just load — `warmUp` deliberately does
    /// not, and would not help here. One token is enough to touch every layer.
    ///
    /// It runs the router's own system prompt rather than a throwaway string,
    /// which costs the same and keeps that prompt at the front of Ollama's
    /// prompt cache too. The router is the call the user waits on with
    /// "Thinking…" on screen, so it is the one worth holding warm.
    @discardableResult
    static func keepWarm(system: String, config: Config) async -> Bool {
        let reply = try? await complete(
            system: system, user: "instruction: hello",
            json: false, maxTokens: 1, config: config
        )
        return reply != nil
    }

    /// Loads the model into Ollama's memory without asking it anything.
    ///
    /// A request with no prompt is Ollama's documented "just load it" call, so
    /// this costs the load and no inference. Called at launch, it moves the
    /// 7–10s cold start (see `pinned`) to a moment when nobody is waiting on
    /// it; `keep_alive` then stops it coming back.
    ///
    /// Returns whether the model ended up loaded, for the log only. Silent on
    /// failure: Ollama not being installed is an ordinary state for this app,
    /// and the features that need it already say so at the point of use.
    ///
    /// The timeout is generous rather than `config.timeout` because it is
    /// bounded by disk speed on a multi-GB file, not by how long a user will
    /// wait — nobody is watching this one.
    @discardableResult
    static func warmUp(config: Config) async -> Bool {
        guard let url = URL(string: "\(config.endpoint)/api/generate") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": config.model]
        // Omitted rather than sent as 0 when not pinning: 0 means "unload now",
        // which would make warming up mean nothing at all.
        if config.keepLoaded { body["keep_alive"] = pinned }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        guard
            let (_, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
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

    /// Everything said after a wake phrase, or nil for plain dictation.
    /// Empty string means the phrase was said on its own.
    ///
    /// Shared by the app and by `--command`; when these were two copies, the
    /// test harness silently exercised different logic from the app.
    ///
    /// Several phrases are tried and the best-scoring one wins, rather than the
    /// first that clears the bar. They overlap on purpose — "hey parrot" and
    /// "by the way parrot" share their distinctive word — so first-past-the-post
    /// would let a poor match on one phrase beat a good match on another and
    /// swallow a different number of words.
    static func commandAfterWakePhrase(_ text: String, phrases: [String]) -> String? {
        var best: (score: Double, command: String)?
        for phrase in phrases {
            guard let found = match(text, phrase: phrase) else { continue }
            if best == nil || found.score > best!.score { best = found }
        }
        return best?.command
    }

    /// An instruction said *inside* a dictation, and the text it applies to.
    ///
    ///     "there is a bug in get username by the way parrot format it"
    ///      └─ text ────────────────────┘        └─ instruction ─────┘
    ///
    /// The point is one breath instead of two. Saying it afterwards means a
    /// second dictation, and a transform that has to find its target again —
    /// reading a selection, or editing a field in place, which is where the
    /// risk lives. Here the target is the same utterance and nothing has been
    /// written yet.
    ///
    /// Exact, unlike the prefix matcher. That one is fuzzy because the wake
    /// phrase is the first thing said and the audio engine is still starting
    /// up, so "hey parrot" arrives clipped or misheard. Mid-sentence the audio
    /// is clean, and there is a whole sentence of ordinary words for a fuzzy
    /// match to fire on — "…the parrots are loud…" would split a sentence in
    /// two and send half of it to a model.
    ///
    /// Nil when no phrase is found, or when one is found at the very start:
    /// that is the whole utterance being a command, which is a different thing
    /// and already handled.
    static func inlineInstruction(
        _ text: String, phrases: [String]
    ) -> (text: String, instruction: String)? {
        var best: (range: NSRange, length: Int)?
        let whole = NSRange(text.startIndex..., in: text)

        for phrase in phrases {
            let words = phrase
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            // Punctuation between the words because a transcript has it —
            // "by the way, parrot" is what gets written down when you pause.
            let pattern = "\\b" + words.joined(separator: "[\\s,]+") + "\\b"
            guard let expression = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { continue }

            for match in expression.matches(in: text, range: whole) {
                guard match.range.location > 0 else { continue }
                // Earliest wins, so the text is everything you said before
                // changing your mind. On a tie the longer phrase wins: "by the
                // way parrot" and "parrot" start in different places, but two
                // phrases sharing a start would otherwise be decided by the
                // order they happen to sit in the config.
                if let found = best,
                   match.range.location > found.range.location
                    || (match.range.location == found.range.location
                        && match.range.length <= found.length) {
                    continue
                }
                best = (match.range, match.range.length)
            }
        }

        guard let best, let split = Range(best.range, in: text) else { return nil }
        let before = String(text[..<split.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:—-"))
            .trimmingCharacters(in: .whitespaces)
        let after = String(text[split.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:—-"))
            .trimmingCharacters(in: .whitespaces)

        // Nothing before it is the command case wearing a disguise, and nothing
        // after it is a phrase said for its own sake — neither has an edit in
        // it, and guessing would rewrite a sentence nobody asked about.
        guard !before.isEmpty, !after.isEmpty else { return nil }
        return (before, after)
    }

    /// One phrase, and how well it matched — the score is what lets the caller
    /// choose between phrases.
    private static func match(_ text: String, phrase rawPhrase: String) -> (score: Double, command: String)? {
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
        // which is what a clipped "hey" leaves behind. Scored below any real
        // match, so a phrase that matched properly always wins over one that
        // only recognised its own last word.
        if matchedWords == nil, let keyword = phraseWords.last, keyword.count >= 4 {
            let score = similarity(normalised[0], keyword)
            if score >= 0.8 {
                matchedWords = 1
                bestScore = score * 0.5
            }
        }

        guard let matchedWords else { return nil }

        guard spokenWords.count == normalised.count else {
            return (bestScore, normalised.dropFirst(matchedWords).joined(separator: " "))
        }
        return (bestScore, spokenWords.dropFirst(matchedWords)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines))
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
    /// Asks the model which word in the transcript the speaker meant to fix.
    ///
    /// The model picks the span only; the spelling comes from the letters via
    /// `spelledOutWord`. Scored against tests/spelling-cases.yaml — 39 names
    /// across French, Indian, Chinese, Turkish, Vietnamese, Korean, Nigerian,
    /// Polish, Irish and Arabic, plus split product names and negative cases,
    /// on gemma4:e4b with prompt v8:
    ///
    ///     span only             39/39
    ///     span + model spelling 37/39
    ///     what this returns     38/39
    ///
    /// The two the model loses are both it mangling letters it was copying —
    /// "S I O B H A N" came back "Sibhan". That job belongs to the regex.
    ///
    /// The one this loses is "Sam spells S A M", where the guard below drops a
    /// rule mapping a word to itself. That is deliberate, so the set's
    /// expectation for that case is what is wrong.
    ///
    /// The fallback matters more than the prompt on a weak model: it repaired
    /// granite4:3b from 85% to 92%, and it is most of the reason
    /// qwen3.5:0.8b's 62% is barely above the 59% that no model at all scores.
    static func interpret(
        command: String,
        lastTranscript: String?,
        language: String = "en",
        config: LocalLLM.Config
    ) async throws -> VoiceCommand {
        let system = extractionPrompt(for: language)

        var user = "source: \(lastTranscript ?? "")\ncorrection: \(command)"
        if lastTranscript?.isEmpty != false {
            user = "source: (nothing yet)\ncorrection: \(command)"
        }

        let raw = try await LocalLLM.complete(
            system: system, user: user, json: false, config: config
        )
        let reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // "I like apples => NO MATCH" is the right decision, clumsily phrased.
        if reply.range(of: "no match", options: .caseInsensitive) != nil || reply.isEmpty {
            return .unrecognised(command)
        }

        // Both shapes are accepted, because the two prompts answer differently
        // and a missing arrow was previously a total loss rather than a
        // formatting one. English (v14) replies with the span alone; French
        // (v13) still writes "span => spelling", which is not decoration there
        // — measured span-only on French and it cost ten points, the model
        // under-trimming "Say goal enn" to "Say goal" once it no longer had to
        // write the name out. Spelling out the target evidently disciplines
        // the span. English does not need the crutch and is 61 tokens lighter
        // without it.
        let heard: String
        let modelSpelling: String
        if let arrow = reply.range(of: "=>") {
            heard = reply[reply.startIndex..<arrow.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            modelSpelling = reply[arrow.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
        } else {
            heard = reply
                .components(separatedBy: .newlines).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            modelSpelling = ""
        }

        guard !heard.isEmpty else { return .unrecognised(command) }

        // The letters are unambiguous; the model's version of them is not.
        let corrected = spelledOutWord(in: command) ?? modelSpelling
        guard !corrected.isEmpty else { return .unrecognised(command) }

        // Catch the model naming a word that is not actually in the transcript
        // — it either copied from the command, where the name was misheard a
        // second time, or invented one.
        let resolved: String
        if let transcript = lastTranscript, !transcript.isEmpty,
           !containsWord(heard, in: transcript) {
            Log.write("command: \"\(heard)\" is not in the transcript, matching instead")
            resolved = [corrected, heard]
                .compactMap { candidate -> (String, Double)? in
                    guard let match = closestWord(to: candidate, in: transcript) else { return nil }
                    return (match, similarity(match, candidate))
                }
                .max { $0.1 < $1.1 }?.0 ?? heard
        } else {
            resolved = heard
        }

        guard resolved.lowercased() != corrected.lowercased() else {
            return .unrecognised(command)
        }
        return .addRule(heard: resolved, corrected: corrected)
    }

    /// Prompt v8. Earlier versions and the scores that rejected them are in
    /// scripts/validate-prompt.py, which reruns the set in about a minute.
    ///
    /// Three things it took measurement to learn. "Output nothing" for the
    /// no-match case does not work — a model will not emit zero tokens, so it
    /// invents a mapping instead; `NO MATCH` gives it somewhere to go and took
    /// the set from 71% to 89%. A prose rule against including surrounding
    /// words over-trimmed real names ("Anna ees" to "Anna"); the same lesson
    /// carried by two examples instead cost nothing.
    ///
    /// And v8 deleted "including when the nearest candidate is an ordinary
    /// English word" from the NO MATCH rule. It was meant to protect the
    /// negative cases, but the examples already do that, and the clause fired
    /// on the names that *are* ordinary English words — Clark/Clerk and
    /// Becker/Bekir came back NO MATCH. Removing it changed gemma4:e4b not at
    /// all and took granite4:3b from 90% to 92%: a rule that only ever cost
    /// something. The negative cases did not regress.
    /// The prompt for a dictation language, English for anything unlisted.
    ///
    /// A prompt written in the user's language is worth having but only on a
    /// capable model: on gemma4:e4b the French prompt scores 93% against the
    /// English prompt's 87% on tests/french-cases.yaml, while on granite4:3b it
    /// scores 48% against 68% — down to what no model at all scores. It removes
    /// the English scaffolding a weaker model was leaning on, so this table is
    /// a reason to keep the larger model rather than a way to shrink it.
    static func extractionPrompt(for language: String) -> String {
        extractionPrompts[language] ?? extractionPrompt
    }

    static let extractionPrompts: [String: String] = [
        "en": extractionPrompt,
        "fr": frenchExtractionPrompt,
    ]

    /// Prompt v14: v8 with the right-hand side deleted.
    ///
    /// Latency here is prefill, not generation — measured on e4b, 420 prompt
    /// tokens in against 6 out, 0.87s reading the prompt against 0.13s writing
    /// the answer. Ollama only reuses its cache when the new prompt strictly
    /// extends the cached one, and a fresh dictation never does, so every call
    /// re-reads the whole prompt at about 2.1ms per token. The prompt's length
    /// *is* the latency, and the arrow and the spelling after it were being
    /// generated and then discarded — `spelledOutWord` has always built the
    /// real spelling from the letters.
    ///
    /// Deleting them cost nothing and saved 61 prompt tokens and 3 output
    /// tokens: 1.33s to 1.15s, with the model's own score unchanged at 44/44,
    /// reproduced on a second run.
    ///
    /// Cutting further was measured and rejected — the examples are load
    /// bearing, and they fail in the expensive direction. Scores in
    /// scripts/validate-prompt.py; in short, four examples (v15) scored 95%
    /// and two (v16) 86%, both by inventing matches for "The weather is nice
    /// today" and "I like apples". A false positive writes a rule that rewrites
    /// every future transcript, so the two NO MATCH examples pay for
    /// themselves. Compressing the prose instead (v18) was worse again, 93%,
    /// over-trimming "Oluwa shane" to "shane".
    static let extractionPrompt = """
    Find the words in the source line that the speaker is correcting.

    You get a source transcription, and a correction transcription in which \
    the speaker says a name then spells it letter by letter.

    Reply with those words copied from the source line, and nothing else.
    Or reply NO MATCH.

    - Copy the words from the SOURCE. The correction transcription mishears \
    the name a second time; ignore how it appears there.
    - The source span is often two or three words, because recognition splits \
    names it does not know. Take the whole name, and only the name.
    - Reply NO MATCH when nothing in the source sounds like the spelled name.

    source: I work with Tasmin
    correction: Das mean spells T-A-S-M-E-E-N
    Tasmin

    source: I work with Sarah
    correction: Tasmin spells T-A-S-M-E-E-N
    NO MATCH

    source: I like apples
    correction: Oranges spells O-R-A-N-G-E-S
    NO MATCH

    source: We deployed to Versal yesterday
    correction: Versoff spells V E R C E L
    Versal

    source: The Coober netties cluster is down
    correction: Kuber nettis spells K U B E R N E T E S
    Coober netties

    source: When is handling the deploy
    correction: New yen spells N G U Y E N
    When

    source: Anna ees joined the design team
    correction: Anna east spells A N A I S
    Anna ees
    """

    /// The English prompt's structure, in French, with French examples.
    ///
    /// 93% on tests/french-cases.yaml against the English prompt's 87%, and it
    /// gains them in the right place: the English prompt's French failures were
    /// spans running on into French function words ("Mets-le derrière Cloud
    /// fair"), and these examples stop that.
    ///
    /// "marche => Marc" is the French counterpart of the English prompt's
    /// "When => Nguyen": an ordinary word that is in fact the misheard name.
    ///
    /// Written without accents, which was not deliberate but is what scored
    /// 93%. Adding them is a change to measure, not to assume.
    ///
    /// Keeps the "span => spelling" shape that English dropped for speed, and
    /// that asymmetry is measured, not an oversight: span-only French (v19)
    /// fell from 93% to 83%, twice, by under-trimming — "Say goal enn" came
    /// back "Say goal", "Anna ees" came back "Anna". Writing the target name
    /// out evidently makes the model commit to a span long enough to spell it,
    /// and French needs that where English does not. The 0.3s it costs buys ten
    /// points.
    ///
    /// Two attempts at the remaining pair failed and are not worth repeating:
    /// a fourth negative built from a product name (v20), aimed at the false
    /// positive, and a three-word example (v21), aimed at the short span.
    /// Both scored 93% with the same two failures.
    static let frenchExtractionPrompt = """
    Associe un nom mal transcrit a l'orthographe que la personne vient d'epeler.

    Tu recois une transcription source, et une transcription de correction dans \
    laquelle la personne dit un nom puis l'epelle lettre par lettre.

    Reponds par une seule ligne, et rien d'autre :
    <les mots exactement comme ils apparaissent dans la source> => <les lettres epelees assemblees>
    ou
    NO MATCH

    - La partie gauche doit etre copiee caractere par caractere depuis la \
    SOURCE. La transcription de correction se trompe une seconde fois sur le \
    nom ; ignore la facon dont il y apparait.
    - Le nom occupe souvent deux ou trois mots dans la source, parce que la \
    reconnaissance vocale decoupe les noms qu'elle ne connait pas. Prends le \
    nom entier, et rien que le nom.
    - La partie droite est constituee des lettres epelees, dans l'ordre donne, \
    assemblees avec une majuscule au debut.
    - Reponds NO MATCH si rien dans la source ne ressemble au nom epele.

    source: J'ai vu Ni cola hier au bureau
    correction: Nicolas s'ecrit N I C O L A S
    Ni cola => Nicolas

    source: J'ai vu Sophie hier au bureau
    correction: Nicolas s'ecrit N I C O L A S
    NO MATCH

    source: Il pleut beaucoup en ce moment
    correction: Oranges s'ecrit O R A N G E S
    NO MATCH

    source: On utilise Post gres pour les donnees
    correction: Postgresse s'ecrit P O S T G R E S
    Post gres => Postgres

    source: Le cluster Elastic serge est lent
    correction: Elastic search s'ecrit E L A S T I C S E A R C H
    Elastic serge => Elasticsearch

    source: Il faut que ca marche demain
    correction: Marc s'ecrit M A R C
    marche => Marc

    source: Cle mence a rejoint l'equipe hier
    correction: Clemence s'ecrit C L E M E N C E
    Cle mence => Clemence
    """

    /// Whether `word` actually occurs in `transcript`, ignoring case and
    /// punctuation. Multi-word values are matched as a phrase.
    static func containsWord(_ word: String, in transcript: String) -> Bool {
        func tokens(_ value: String) -> [String] {
            value.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted)
                .filter { !$0.isEmpty }
        }
        let needle = tokens(word)
        let haystack = tokens(transcript)
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
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

        guard let best, best.score >= 0.6 else { return nil }
        return best.text
    }

    /// Letter pairs speech recognition swaps constantly. A d/t or m/n
    /// substitution says almost nothing about whether two renderings are the
    /// same word, so it costs half as much as an unrelated letter.
    private static let confusable: [Set<Character>] = [
        ["b", "p"], ["d", "t"], ["g", "k"], ["v", "f"], ["z", "s"],
        ["m", "n"], ["l", "r"], ["j", "g"], ["c", "k"], ["c", "s"],
        ["a", "e", "i", "o", "u", "y"],
    ]

    private static func substitutionCost(_ a: Character, _ b: Character) -> Double {
        if a == b { return 0 }
        for group in confusable where group.contains(a) && group.contains(b) {
            return 0.5
        }
        return 1
    }

    /// 1 - (weighted edit distance / longer length), case- and space-insensitive.
    ///
    /// Plain edit distance rates "Dasmi" against "Tasneen" at 29%, below any
    /// usable threshold, even though they are the same name heard twice.
    /// Discounting confusable letters lifts that to 50% and "Tasni"/"Dasmi"
    /// from 60% to 80%, while unrelated words stay low: "weather"/"Tasneen"
    /// only reaches 21%.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { !$0.isWhitespace })
        let y = Array(b.lowercased().filter { !$0.isWhitespace })
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y { return 1 }

        var previous = (0...y.count).map(Double.init)
        var current = [Double](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = Double(i)
            for j in 1...y.count {
                let cost = substitutionCost(x[i - 1], y[j - 1])
                current[j] = Swift.min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return 1 - previous[y.count] / Double(Swift.max(x.count, y.count))
    }

    /// Words that end the spelling: "spelled S U P A B A S E not super base",
    /// or "s'écrit R E D I S pas Reddis".
    ///
    /// The French half is not optional now that French trigger words are
    /// recognised. Before, "s'écrit" missed the trigger and fell through to the
    /// single-letter fallback, which stopped on its own; now the greedy path
    /// runs for French too and glued the rest of the sentence on, turning
    /// "P I E R R E pas Pierrot" into "Pierrepaspierrot".
    private static let spellingStopWords: Set<String> = [
        "not", "instead", "rather", "but", "no",
        "pas", "non", "plutôt", "plutot", "mais",
    ]

    /// The spelling the speaker read out.
    ///
    /// Everything after "spells" / "is spelled" is taken and joined, however
    /// the recogniser chose to chunk it. It rarely keeps letters separate for
    /// long: "T A S M E E N" comes back as "T A S M Een", "Tas Meen" or
    /// "Tas, M Een", and matching only runs of single letters lost everything
    /// after the point where it started merging — "Tasmin spells Tas Meen"
    /// yielded nothing at all, and "T A S M Een" yielded "Tasm".
    ///
    /// Verified against every command logged in a session of real use: 17/17,
    /// against 8/17 for the single-letter pattern alone.
    ///
    /// The French triggers are here rather than left to that fallback for the
    /// same reason. "Mathieu s'écrit M A T H Ieu" has both a trigger the list
    /// did not know and a merged tail, so it fell through to the single-letter
    /// pattern and yielded "Math". Adding them took tests/french-cases.yaml
    /// from 76% to 84% on gemma4:e4b, and left the English set at 97%.
    static func spelledOutWord(in text: String) -> String? {
        if let trigger = text.range(
            of: "(?:\\b(?:spells?|spelled|spelling)\\b"
                + "|s['’]\\s*(?:é|e)(?:crit|pelle)"
                + "|\\b(?:é|e)(?:crit|pelle)\\b)",
            options: [.regularExpression, .caseInsensitive]
        ) {
            var letters = ""
            for token in text[trigger.upperBound...]
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter({ !$0.isEmpty }) {
                // Never on the first token. Recognition merges letters into
                // syllables, so "Pascal s'écrit Pas cal" opens on something
                // that reads as a stop word; breaking there would yield
                // nothing at all rather than "Pascal".
                if !letters.isEmpty, spellingStopWords.contains(token.lowercased()) { break }
                letters += token
            }
            if letters.count >= 2 {
                return letters.prefix(1).uppercased() + letters.dropFirst().lowercased()
            }
        }

        // No trigger word: fall back to a run of single letters anywhere.
        let pattern = "\\b(?:[A-Za-z0-9][\\s\\-.]+){2,}[A-Za-z0-9]\\b"
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let letters = text[range].filter { $0.isLetter || $0.isNumber }
        guard letters.count >= 3 else { return nil }
        return letters.prefix(1).uppercased() + letters.dropFirst().lowercased()
    }

}
