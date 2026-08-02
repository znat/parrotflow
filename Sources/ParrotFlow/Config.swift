import Foundation
import Yams

enum ConfigError: LocalizedError {
    case invalidValue(key: String, value: String, expected: String)

    var errorDescription: String? {
        switch self {
        case .invalidValue(let key, let value, let expected):
            return "\(key): \"\(value)\" is not valid — expected \(expected)."
        }
    }
}

/// Everything the app reads from `~/.config/parrotflow/config.yaml`.
///
/// The file is written from `Config.defaultYAML` on first launch and re-read
/// whenever it changes on disk, so iterating on a hotkey is edit-and-save.
/// Decodable and not Encodable: nothing has ever written a Config back out —
/// `defaultYAML` is what a file is created from — and `prompts` is now a view
/// over `transforms` rather than storage, which there is no honest way to
/// encode.
struct Config: Decodable, Equatable {
    var hotkey: Hotkey = Hotkey()
    var audio: Audio = Audio()
    var feedback: Feedback = Feedback()
    var transcription: Transcription = Transcription()
    var llm: LLM = LLM()
    /// Everything nameable: `transforms:`, plus anything still written under
    /// the older `prompts:`.
    var transforms: [Transform] = []

    /// The prompt-bodied transforms, in order.
    ///
    /// Computed rather than stored so there is one list to keep straight. Every
    /// existing caller — the catalogue, the router, `PromptRunner`, the panels
    /// — asks for prompts and still gets exactly what it used to; a `replace:`
    /// transform is simply not one of them.
    var prompts: [Prompt] { transforms.compactMap(\.asPrompt) }

    func transform(named name: String) -> Transform? {
        transforms.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Do what was asked even when no prompt matches — see `FreeForm`.
    ///
    /// On by default. It is the difference between a fixed menu of commands
    /// and being able to say what you want, and the measurements behind that
    /// default are in scripts/validate-generic.py.
    ///
    /// The flag exists because it moves where the app fails. With it off, an
    /// instruction nothing handles is refused and you lose nothing. With it on,
    /// a sentence that was never an instruction can reach a prompt whose job is
    /// to rewrite your selection. The router is what stops that — it answers
    /// NONE for "not an edit" and ANY for "an edit with no tool", measured at
    /// 18/19 — and `confirm` is what makes the residue survivable.
    var freeForm: Bool = true

    enum CodingKeys: String, CodingKey {
        case hotkey, audio, feedback, transcription, llm, transforms, prompts
        case freeForm = "free_form"
    }

    /// One entry of `transforms:` as it is written, before it is known to be
    /// valid. `content:` is accepted alongside `prompt:` because that is what
    /// `prompts:` has always called it, and moving a section should not mean
    /// renaming a key inside every entry of it.
    private struct TransformEntry: Decodable {
        var name = ""
        var description = ""
        var confirm = true
        var body: Transform.Body?
        /// `prompt:` and `replace:` on the same entry.
        var namesBoth = false

        enum CodingKeys: String, CodingKey {
            case name, description, confirm, prompt, content, replace
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func trimmed(_ key: CodingKeys) throws -> String {
                (try c.decodeIfPresent(String.self, forKey: key) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            name = try trimmed(.name)
            description = try trimmed(.description)
            confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? true

            let instructions = try trimmed(.prompt).isEmpty ? trimmed(.content) : trimmed(.prompt)
            let table = try c.decodeIfPresent([String: [String]].self, forKey: .replace)
            namesBoth = !instructions.isEmpty && table != nil
            if let table {
                body = .replace(table)
            } else if !instructions.isEmpty {
                body = .prompt(instructions)
            }
        }
    }

    /// A `transforms:` section, wherever it is written.
    ///
    /// Exposed so a `--pipeline` fixture can carry one and have it read by the
    /// type that reads the real thing, rather than by a second parser that
    /// would be free to disagree about what a transform is.
    static func transforms(from decoder: Decoder) throws -> [Transform] {
        assembled(try [TransformEntry](from: decoder))
    }

    /// The entries worth keeping, with a line in the log for each that is not.
    ///
    /// An entry with no name, or with no body to run, cannot be routed to or
    /// run, and dropping it silently is how a typo becomes an evening. Reported
    /// rather than thrown, so one bad entry does not cost you the rest.
    private static func assembled(_ entries: [TransformEntry]) -> [Transform] {
        var kept: [Transform] = []
        for entry in entries {
            guard !entry.name.isEmpty else {
                Log.write("transforms: skipped an entry with no name")
                continue
            }
            if entry.namesBoth {
                // Preferring one would run something the config did not ask
                // for, on text nobody sees beforehand.
                Log.write("transforms: \"\(entry.name)\" names both `prompt:` and `replace:`; skipped")
                continue
            }
            guard let body = entry.body else {
                Log.write("transforms: \"\(entry.name)\" has neither `prompt:` nor `replace:`; skipped")
                continue
            }
            guard !kept.contains(where: {
                $0.name.caseInsensitiveCompare(entry.name) == .orderedSame
            }) else {
                // First wins, which puts `transforms:` ahead of the older
                // `prompts:` — a config carrying both has moved an entry and
                // not yet deleted the old one.
                Log.write("transforms: \"\(entry.name)\" is defined twice; kept the first")
                continue
            }
            if entry.description.isEmpty {
                Log.write("transforms: \"\(entry.name)\" has no description; the router cannot pick it")
            }
            kept.append(Transform(
                name: entry.name, description: entry.description,
                confirm: entry.confirm, body: body
            ))
        }
        return kept
    }

    /// A named thing that takes text and gives text back.
    ///
    /// Two bodies, because the two ways to rewrite a transcript have nothing in
    /// common but their shape. A `prompt:` asks the local model, costs about a
    /// second and can do what no table expresses. A `replace:` is a
    /// substitution table of its own, costs nothing, and is exact.
    ///
    /// They live in one list because everything downstream wants them in one
    /// list: a pipeline step names either with `transform:`, and the voice
    /// router reads the same `description` off both. Two sections would have
    /// meant two namespaces for one question — "what can this app do to my
    /// text" — and a pipeline key per kind.
    ///
    /// `replace:` exists because `transcription.replacements` is a single table
    /// applied by a single stage: it cannot be two tables running in two places
    /// under two conditions. Wanting "user dot name" to become `user.name` in a
    /// terminal and `` `user.name` `` in chat is what a named table is for.
    struct Transform: Equatable {
        var name: String
        var description: String
        /// Show the result and wait before replacing anything. Only consulted
        /// when a transform is run over your selection — a pipeline stage runs
        /// on a transcript nobody has seen yet, so there is nothing to confirm.
        var confirm: Bool = true
        var body: Body

        enum Body: Equatable {
            /// Instructions for the local model.
            case prompt(String)
            /// A table of its own, in the shape of `transcription.replacements`
            /// — the spelling you want, and the ways it comes out wrong.
            case replace([String: [String]])
        }

        var isPrompt: Bool {
            if case .prompt = body { return true }
            return false
        }

        /// The prompt-shaped view of this transform, for everything that
        /// already speaks `Prompt` — the router, `PromptRunner`, the panels.
        var asPrompt: Prompt? {
            guard case .prompt(let content) = body else { return nil }
            return Prompt(
                name: name, description: description, content: content, confirm: confirm
            )
        }

        /// The rules a `replace:` body applies, flattened.
        var rules: [Transcription.Rule] {
            guard case .replace(let table) = body else { return [] }
            return Transcription.rules(from: table)
        }
    }

    /// An instruction you can reach by voice: "hey parrot, make that a list".
    ///
    /// The description is not documentation — it is the only thing the router
    /// sees when deciding where a spoken instruction goes, so it is doing real
    /// work and wants to read like the thing you would say.
    ///
    /// `content` is the standing rule. What you actually said arrives
    /// separately, because the same prompt has to serve "format those dates
    /// ISO" and "format those dates with slashes" — see `Router`.
    struct Prompt: Codable, Equatable {
        var name: String
        var description: String
        var content: String
        /// Show the result and wait for you before replacing anything.
        ///
        /// On by default: a transform overwrites text you selected, triggered
        /// by voice, with no dialog in the way. Turn it off per prompt once
        /// that prompt has earned it.
        var confirm: Bool = true

        enum CodingKeys: String, CodingKey {
            case name, description, content, confirm
        }

        init(name: String, description: String, content: String, confirm: Bool = true) {
            self.name = name
            self.description = description
            self.content = content
            self.confirm = confirm
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try c.decodeIfPresent(String.self, forKey: .name) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            description = (try c.decodeIfPresent(String.self, forKey: .description) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            content = (try c.decodeIfPresent(String.self, forKey: .content) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? true
        }

        /// Where the spoken instruction goes if the prompt asks for it inline.
        static let instructionPlaceholder = "{{instruction}}"

        var wantsInstructionInline: Bool {
            content.contains(Self.instructionPlaceholder)
        }
    }

    /// A local Ollama model, used to interpret spoken commands.
    struct LLM: Codable, Equatable {
        var enabled: Bool = true
        var model: String = "gemma4:e4b"
        var endpoint: String = "http://localhost:11434"
        var timeoutSeconds: Double = 20
        /// Load the model at launch and pin it in Ollama's memory. Trades a few
        /// GB of RAM for corrections that answer in 1–2s instead of 7–10s.
        var keepLoaded: Bool = true

        enum CodingKeys: String, CodingKey {
            case enabled, model, endpoint
            case timeoutSeconds = "timeout_seconds"
            case keepLoaded = "keep_loaded"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let v = try c.decodeIfPresent(Bool.self, forKey: .enabled) { enabled = v }
            if let v = try c.decodeIfPresent(String.self, forKey: .model) { model = v }
            if let v = try c.decodeIfPresent(String.self, forKey: .endpoint) { endpoint = v }
            if let v = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) { timeoutSeconds = v }
            if let v = try c.decodeIfPresent(Bool.self, forKey: .keepLoaded) { keepLoaded = v }
        }
    }

    struct Transcription: Codable, Equatable {
        var enabled: Bool = true
        /// `paste` types the transcript into the frontmost app (needs
        /// Accessibility). `clipboard` just copies it and lets you paste.
        var insertMode: InsertMode = .paste
        /// Say this instead of dictating, and what follows is an instruction
        /// rather than text. Empty disables it.
        ///
        /// Called `correction_phrase` when the only instruction was fixing a
        /// spelling; that key still works and is still in configs written
        /// before prompts existed.
        var activationPhrase: String = "hey parrot"
        /// Last-resort in-place correction for surfaces the accessibility API
        /// cannot write, such as terminals: clear the input line with readline
        /// keys and retype it.
        ///
        /// On by default, because a terminal is where a developer dictates and
        /// without this a correction there does nothing. It clears the line to
        /// do it, so it only fires when the line is recognisably one we wrote —
        /// that guard is what makes the default defensible.
        var rewriteLine: Bool = true
        /// Languages you dictate in, most common first.
        ///
        /// Not passed to Parakeet — it transcribes multilingually on its own
        /// and reports no language. The list is what constrains ParrotFlow's
        /// own language detection, which is why naming only the languages you
        /// actually use makes it more accurate, and it selects the correction
        /// prompt written for that language. One entry means no detection runs
        /// at all.
        var languages: [String] = ["en"]

        enum InsertMode: String, Codable, Equatable {
            case paste
            case clipboard
        }

        enum CodingKeys: String, CodingKey {
            case enabled, replacements, pipelines, languages
            case insertMode = "insert_mode"
            case activationPhrase = "activation_phrase"
            case rewriteLine = "rewrite_line"
        }

        /// Keys that are read but never written. Kept out of `CodingKeys` so
        /// the synthesised encoder doesn't need a property for a name we no
        /// longer use.
        private enum LegacyKeys: String, CodingKey {
            case correctionPhrase = "correction_phrase"
            // Retired into `pipelines:`. Still read, only so that a config
            // carrying them can be told so — see `retired`.
            case numbers
            case fuzzyMatching = "fuzzy_matching"
        }
        /// Grouped by the word you want written, since one name accumulates
        /// several mishearings — eleven rules had built up for four names
        /// before this was grouped.
        ///
        ///     replacements:
        ///       Tasmeen: [Tasmid, Tasmin, Tasmine]
        var replacements: [String: [String]] = [:]
        /// What a finished transcript goes through, in order, per language —
        /// see `Pipeline`. A language's own list wins over `default`.
        ///
        /// Empty here means the config said nothing, not that nothing should
        /// run: `Pipeline.unconfigured` decides that. A new install is written
        /// with every stage listed, so the answer to "what else could go here"
        /// is in the file rather than in the documentation.
        var pipelines: [String: Pipeline] = [:]

        /// Keys this config still carries that no longer do anything.
        ///
        /// `numbers` and `fuzzy_matching` became stages. The decoder ignores
        /// keys it does not know, so a config still setting them would lose
        /// two passes without a word — which is the one outcome a rename must
        /// not have. They are read here purely so `--check-config` can refuse
        /// them and say what to write instead.
        var retired: [String] = []

        /// Stage names in `pipelines:` that are not stages. Dropped from the
        /// pipeline, kept here: a line silently doing nothing is the same
        /// failure as a retired key, and the log is not where anyone looks.
        var unknownStages: [String] = []

        /// `pipelines:` keys that are neither `default` nor a configured
        /// language. Stored and never used otherwise — the pipeline someone
        /// wrote for `french:` or `de:` would simply never run.
        var unknownPipelineLanguages: [String] = []

        /// Entries naming both `stage:` and `prompt:`. Their own list, because
        /// "grammar is not a stage" is not what went wrong.
        var contradictoryEntries: [String] = []

        /// One rule per mishearing, flattened for the substitution pass.
        var rules: [Rule] { Self.rules(from: replacements) }

        /// Shared with `Transform.replace`, which is the same table in another
        /// place — one flattening, so the two cannot drift.
        static func rules(from table: [String: [String]]) -> [Rule] {
            table.flatMap { target, sources in
                sources.map { Rule(source: $0, replacement: target) }
            }
        }

        /// A single substitution.
        ///
        /// A source wrapped in slashes is a regular expression, which is how
        /// filler words are removed — they need alternation and have to take
        /// their surrounding punctuation with them. Everything else is matched
        /// literally on word boundaries.
        /// One line of a pipeline. Written either way:
        ///
        ///     - numbers
        ///     - stage: numbers
        ///       when: /\\d/
        ///     - prompt: hesitation
        ///       when: /genre/
        ///
        /// A transform names itself with `transform:` rather than
        /// `stage: transform` plus a second key, because every one of them
        /// would need both and a form that repeats itself is a form people
        /// mistype. `prompt:` is the older spelling of the same thing and still
        /// reads, since a prompt is a transform with a prompt body.
        ///
        /// The short form is the one almost every line wants, and a format that
        /// makes the common case verbose is a format people work around.
        struct PipelineEntry: Decodable {
            let name: String
            var transform: String?
            var when: String?
            var unless: String?
            var app: String?
            /// `stage:` and `transform:`/`prompt:` on the same entry.
            var namesBoth = false

            private enum CodingKeys: String, CodingKey {
                case stage, transform, prompt, when, unless, app
            }

            init(from decoder: Decoder) throws {
                if let bare = try? decoder.singleValueContainer().decode(String.self) {
                    name = bare
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let stage = try c.decodeIfPresent(String.self, forKey: .stage)
                let named = try c.decodeIfPresent(String.self, forKey: .transform)
                    ?? c.decodeIfPresent(String.self, forKey: .prompt)
                if let named {
                    name = "transform"
                    transform = named
                    // Both keys on one entry is a contradiction, not a
                    // preference to resolve — recorded so the caller refuses it
                    // rather than dropping whichever it liked less.
                    namesBoth = stage != nil
                } else {
                    name = stage ?? ""
                }
                when = try c.decodeIfPresent(String.self, forKey: .when)
                unless = try c.decodeIfPresent(String.self, forKey: .unless)
                app = try c.decodeIfPresent(String.self, forKey: .app)
            }
        }

        struct Rule {
            let source: String
            let replacement: String

            var isRegex: Bool {
                source.count >= 2 && source.hasPrefix("/") && source.hasSuffix("/")
            }

            /// Deleting rather than substituting. Written as an empty target.
            var isDeletion: Bool { replacement.isEmpty }

            /// The pattern to match, already anchored if it is a literal.
            var pattern: String {
                guard isRegex else {
                    return "\\b\(NSRegularExpression.escapedPattern(for: source))\\b"
                }
                return String(source.dropFirst().dropLast())
            }

            /// What gets written, as the replacement API wants it.
            ///
            /// A literal source keeps a literal target: a name is a word you
            /// want written exactly, and `$` in one has to survive — escaping
            /// is what stops "AT&T" or a price from being read as a group
            /// reference nobody wrote.
            ///
            /// A source in slashes has already said it is a pattern, so its
            /// target is a template and `$1` refers back to what the pattern
            /// captured. That is the only way to write a rule whose output
            /// depends on its input:
            ///
            ///     $1.$2: ['/(\\w+) dot (\\w+)/']    # "user dot name" -> user.name
            ///
            /// Without it a rule can only map a fixed phrase to a fixed one,
            /// and "spoken dotted path" is not a fixed set.
            var template: String {
                isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
            }

            /// Groups the template refers to. `$1` and `${1}`, not `\$1`.
            var referencedGroups: [Int] {
                guard isRegex else { return [] }
                let expression = try? NSRegularExpression(
                    pattern: "(?<!\\\\)\\$\\{?(\\d+)\\}?"
                )
                let range = NSRange(replacement.startIndex..., in: replacement)
                return (expression?.matches(in: replacement, range: range) ?? []).compactMap {
                    guard let group = Range($0.range(at: 1), in: replacement) else { return nil }
                    return Int(replacement[group])
                }
            }

            /// Fuzzy matching compares spellings, so a pattern is not a
            /// candidate and neither is a deletion — there is nothing to match
            /// against.
            var isFuzzyCandidate: Bool { !isRegex && !isDeletion }
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) { self.enabled = enabled }
            if let raw = try c.decodeIfPresent(String.self, forKey: .insertMode) {
                guard let mode = InsertMode(rawValue: raw.lowercased()) else {
                    throw ConfigError.invalidValue(
                        key: "transcription.insert_mode",
                        value: raw,
                        expected: "paste or clipboard"
                    )
                }
                self.insertMode = mode
            }
            // The new name wins if both are present, which is what someone
            // mid-rename would expect.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            if let phrase = try legacy.decodeIfPresent(String.self, forKey: .correctionPhrase) {
                self.activationPhrase = phrase
            }
            if let phrase = try c.decodeIfPresent(String.self, forKey: .activationPhrase) {
                self.activationPhrase = phrase
            }
            if let v = try c.decodeIfPresent(Bool.self, forKey: .rewriteLine) { rewriteLine = v }
            if let v = try c.decodeIfPresent([String].self, forKey: .languages) {
                let known = v.map { $0.lowercased() }
                    .filter { DictationLanguage.supported.contains($0) }
                // An empty or wholly unrecognised list means English rather
                // than no language at all, so a typo degrades instead of
                // leaving the correction prompt undefined.
                languages = known.isEmpty ? ["en"] : known
            }
            // Wrapped, as `replacements:` is below and for the same reason.
            // Anything thrown here leaves `ConfigStore.load()` entirely, and at
            // launch `loadConfig(announceErrors: false)` swallows it — so one
            // mis-shaped key would drop the whole config back to stock defaults:
            // no replacements, the built-in wake phrase, the default hotkey, in
            // silence. The shape most people will get wrong is writing a bare
            // list where a map per language belongs, because `languages:` two
            // lines above is a bare list.
            do {
                if let raw = try c.decodeIfPresent(
                    [String: [PipelineEntry]].self, forKey: .pipelines
                ) {
                    for (language, entries) in raw {
                        let steps = entries.compactMap { entry -> Pipeline.Step? in
                            guard let stage = Pipeline.stage(named: entry.name) else {
                                unknownStages.append(entry.name)
                                return nil
                            }
                            if entry.namesBoth {
                                // Silently preferring one would delete a stage
                                // the config asked for.
                                contradictoryEntries.append(entry.transform ?? "transform")
                                return nil
                            }
                            return Pipeline.Step(
                                stage: stage, transform: entry.transform,
                                when: entry.when, unless: entry.unless, app: entry.app
                            )
                        }
                        let key = language.lowercased()
                        if key != "default", !languages.contains(key) {
                            unknownPipelineLanguages.append(language)
                        }
                        pipelines[key] = Pipeline(steps: steps)
                    }
                }
            } catch {
                throw ConfigError.invalidValue(
                    key: "transcription.pipelines",
                    value: "a bare list, or a language with nothing under it",
                    expected: "a language, then its stages — `default: [replacements, fuzzy]`, "
                        + "or `fr:` with `- replacements` under it"
                )
            }
            // `try?` on an optional decode gives Bool??, and both layers mean
            // "absent" — flattened here so the condition reads as the question
            // being asked: is the key in the file at all.
            func present(_ key: LegacyKeys) -> Bool {
                ((try? legacy.decodeIfPresent(Bool.self, forKey: key)) ?? nil) != nil
            }
            for key in [LegacyKeys.numbers, .fuzzyMatching] where present(key) {
                retired.append(key.stringValue)
            }
            do {
                if let grouped = try c.decodeIfPresent(
                    [String: [String]].self, forKey: .replacements
                ) {
                    self.replacements = grouped
                }
            } catch {
                // The flat `heard: corrected` form was the earlier shape. Say so
                // plainly rather than leaving a type mismatch to be decoded.
                throw ConfigError.invalidValue(
                    key: "transcription.replacements",
                    value: "a flat mapping",
                    expected: "the spelling you want, listing its mishearings — Tasmeen: [Tasmin, Tasmine]"
                )
            }
        }
    }

    struct Hotkey: Codable, Equatable {
        /// Key name understood by `KeyCodes.code(for:)`, e.g. "space", "d", "f13".
        /// Differs between the dev and released builds so both can run at once.
        var key: String = AppVariant.defaultHotkey
        /// Any of: command, control, option, shift (aliases: cmd, ctrl, alt, opt).
        var modifiers: [String] = []
        /// `toggle` — press once to start, once to stop.
        /// `push_to_talk` — record only while held down.
        var mode: Mode = .pushToTalk

        enum Mode: String, Codable, Equatable {
            case toggle
            case pushToTalk = "push_to_talk"

            init(parsing raw: String) throws {
                switch raw.lowercased().replacingOccurrences(of: "-", with: "_") {
                case "toggle": self = .toggle
                case "push_to_talk", "pushtotalk", "ptt", "hold": self = .pushToTalk
                default:
                    throw ConfigError.invalidValue(
                        key: "hotkey.mode",
                        value: raw,
                        expected: "toggle or push_to_talk"
                    )
                }
            }
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let key = try c.decodeIfPresent(String.self, forKey: .key) { self.key = key }
            if let mods = try c.decodeIfPresent([String].self, forKey: .modifiers) { self.modifiers = mods }
            if let mode = try c.decodeIfPresent(String.self, forKey: .mode) {
                self.mode = try Mode(parsing: mode)
            }
        }
    }

    struct Audio: Codable, Equatable {
        /// Parakeet expects 16 kHz mono. Changing this is almost never what you want.
        var sampleRate: Double = 16000
        var outputDir: String = AppVariant.defaultOutputDir
        /// Recordings shorter than this are discarded (guards against fumbled hotkeys).
        var minDurationSeconds: Double = 0.3
        /// Run voice-activity detection before transcribing, and skip clips
        /// with no speech in them. On by default; turn it off if it ever
        /// swallows something real.
        var speechGate: Bool = true

        enum CodingKeys: String, CodingKey {
            case sampleRate = "sample_rate"
            case outputDir = "output_dir"
            case minDurationSeconds = "min_duration_seconds"
            case speechGate = "speech_gate"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let rate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) {
                guard rate >= 8000, rate <= 192_000 else {
                    throw ConfigError.invalidValue(
                        key: "audio.sample_rate",
                        value: String(Int(rate)),
                        expected: "a rate between 8000 and 192000"
                    )
                }
                self.sampleRate = rate
            }
            if let dir = try c.decodeIfPresent(String.self, forKey: .outputDir) { self.outputDir = dir }
            if let min = try c.decodeIfPresent(Double.self, forKey: .minDurationSeconds) {
                self.minDurationSeconds = max(0, min)
            }
            if let gate = try c.decodeIfPresent(Bool.self, forKey: .speechGate) {
                self.speechGate = gate
            }
        }
    }

    struct Feedback: Codable, Equatable {
        /// Play a short system sound on start/stop.
        var sound: Bool = true
        /// Show the floating recording pill near the bottom of the screen.
        var overlay: Bool = true

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let sound = try c.decodeIfPresent(Bool.self, forKey: .sound) { self.sound = sound }
            if let overlay = try c.decodeIfPresent(Bool.self, forKey: .overlay) { self.overlay = overlay }
        }
    }

    init() {}

    /// Hand-rolled so a partial config.yaml is valid: anything you leave out
    /// keeps its default instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) { self.hotkey = hotkey }
        if let audio = try c.decodeIfPresent(Audio.self, forKey: .audio) { self.audio = audio }
        if let feedback = try c.decodeIfPresent(Feedback.self, forKey: .feedback) { self.feedback = feedback }
        if let transcription = try c.decodeIfPresent(Transcription.self, forKey: .transcription) {
            self.transcription = transcription
        }
        if let llm = try c.decodeIfPresent(LLM.self, forKey: .llm) { self.llm = llm }
        // `transforms:` first, then anything still under `prompts:`. Both are
        // read: `prompts:` is what every config written before this existed
        // says, and a rename that silently empties the section is the one
        // outcome a rename must not have.
        var entries = try c.decodeIfPresent([TransformEntry].self, forKey: .transforms) ?? []
        entries += try c.decodeIfPresent([TransformEntry].self, forKey: .prompts) ?? []
        transforms = Self.assembled(entries)
        if let freeForm = try c.decodeIfPresent(Bool.self, forKey: .freeForm) {
            self.freeForm = freeForm
        }
    }

    /// Everything the config says that will not do what it looks like it does.
    ///
    /// One list rather than two, because the version `--check-config` printed
    /// and the version the running app knew about had already drifted: a
    /// mistyped stage name was reported by the command and nowhere else, so an
    /// app running with `replacements` silently missing looked exactly like an
    /// app whose replacement table was empty. The command prints these; the app
    /// logs them at every load.
    /// What is wrong with the replacement table alone.
    ///
    /// Split out of `problems()` so a pipeline fixture can be checked against
    /// it without dragging in the rest: `--pipeline` fixtures name transforms
    /// that deliberately do not exist, and "no transform named" is a case those
    /// sets test rather than a complaint they want raised.
    ///
    /// Covers every table there is, `transcription.replacements` and each
    /// `replace:` transform, because a template is wrong in the same way
    /// wherever it is written.
    func replacementProblems() -> [String] {
        var found: [String] = []
        // A template referring to a group the pattern never captures is
        // written as nothing at all — the rule fires, the output is quietly
        // short, and the log shows a substitution that looks like it worked.
        for rule in transcription.rules + transforms.flatMap(\.rules) {
            let referenced = Set(rule.referencedGroups).sorted()
            guard !referenced.isEmpty,
                  let expression = try? NSRegularExpression(pattern: rule.pattern)
            else { continue }
            for group in referenced where group > expression.numberOfCaptureGroups {
                found.append("replacements: \"\(rule.source)\" writes $\(group), but the pattern"
                    + " captures \(expression.numberOfCaptureGroups) group(s)"
                    + " — $\(group) comes out as nothing")
            }
        }
        return found
    }

    func problems() -> [String] {
        var found: [String] = []
        for key in transcription.retired {
            found.append("transcription.\(key) no longer does anything — it is a pipeline stage now")
        }
        for name in Set(transcription.unknownStages).sorted() {
            found.append("pipelines: \"\(name)\" is not a stage — have: "
                + Pipeline.stageNames.joined(separator: ", "))
        }
        for name in Set(transcription.contradictoryEntries).sorted() {
            found.append("pipelines: an entry names both `stage:` and `prompt: \(name)`"
                + " — it can be one or the other")
        }
        for name in Set(transcription.unknownPipelineLanguages).sorted() {
            found.append("pipelines: \"\(name)\" is not a configured language, so that pipeline never runs"
                + " — configured: \(transcription.languages.joined(separator: ", "))")
        }
        found += replacementProblems()
        for language in transcription.languages {
            let pipeline = Pipeline.resolved(config: self, language: language)
            for problem in pipeline.validate() {
                found.append("pipeline \(language): \(problem)")
            }
            for step in pipeline.steps where step.stage == .transform {
                guard let name = step.transform, !name.isEmpty else { continue }
                if transform(named: name) == nil {
                    found.append("pipeline \(language): no transform named \"\(name)\""
                        + (transforms.isEmpty ? " — `transforms:` is empty"
                            : " — have: \(transforms.map(\.name).joined(separator: ", "))"))
                }
            }
        }
        return found
    }

    var resolvedOutputDir: URL {
        URL(fileURLWithPath: (audio.outputDir as NSString).expandingTildeInPath)
    }
}

// MARK: - Loading

enum ConfigStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AppVariant.configDirectory, isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("config.yaml")
    }

    /// Creates the config file from the template if it does not exist yet.
    static func createIfMissing() throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try defaultYAML.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Reads and decodes the config. Missing keys fall back to the struct defaults.
    static func load() throws -> Config {
        try createIfMissing()
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Config()
        }
        return try YAMLDecoder().decode(Config.self, from: text)
    }

    /// Computed rather than a constant because the dev build seeds a different
    /// hotkey and recordings directory — see `AppVariant`.
    static var defaultYAML: String {
        """
    # \(AppVariant.displayName) configuration
    # Edit and save — changes are picked up automatically. Delete any line to
    # get its default back. `--check-config` says what the file adds up to.

    hotkey:
      # A bare modifier used on its own:
      #   right_option, left_option, right_command, left_command,
      #   right_control, left_control, right_shift, left_shift, fn
      # ...or a character key, which needs modifiers below:
      #   a-z, 0-9, space, return, tab, escape, f1-f20, arrows,
      #   comma, period, slash, semicolon, quote, backslash,
      #   leftbracket, rightbracket, minus, equal, grave, delete
      key: \(AppVariant.defaultHotkey)

      # Any of: command, control, option, shift (aliases: cmd, ctrl, alt, opt).
      modifiers: []

      # push_to_talk records while the key is held; toggle taps on and off.
      # Bare modifiers want push_to_talk — on toggle, Right Option would start
      # recording every time you typed an accented character with it.
      mode: push_to_talk

    audio:
      # Where the recordings pile up.
      output_dir: \(AppVariant.defaultOutputDir)

      # Check for speech before transcribing, and skip clips that have none.
      # Without it a stray hotkey press decodes room tone into "Yeah." or
      # "Thank you for watching". Turn off if it ever swallows real speech.
      speech_gate: true

    feedback:
      sound: true     # a click when recording starts and stops
      overlay: true   # the floating pill while you speak

    transcription:
      # paste     -> typed into the app you're in (needs Accessibility)
      # clipboard -> copied, you press Cmd-V
      insert_mode: paste

      # Say this instead of dictating and what follows is an instruction:
      # "hey parrot, make that a bullet list". Empty disables it.
      activation_phrase: hey parrot

      # Last resort for fields Accessibility cannot write, terminals mostly:
      # clear the input line with Ctrl-A Ctrl-K and retype it corrected. It
      # only fires when the line still holds what you dictated.
      rewrite_line: true

      # Languages you dictate in, most spoken first — the first one is the
      # fallback for transcripts too short to judge, under four words.
      # Supported: en, fr. A single entry means no detection runs at all.
      #
      # Not sent to Parakeet, which transcribes multilingually by itself and
      # reports no language back. This is the list ParrotFlow chooses between,
      # so naming only what you actually speak makes it more accurate.
      languages: [en]

      # What a finished transcript runs through, in order. Listed in full
      # because a stage runs only if it is here: switching one off is deleting
      # a line you can see.
      #
      #   replacements  the table below
      #   fuzzy         the same table against words the spell checker does not
      #                 know, so "super bays" still reaches Supabase without
      #                 "Excel" becoming "Vercel". Needs replacements before it
      #   numbers       "two hundred forty-three" -> 243, plus ordinals,
      #                 decimals and years, English and French
      #
      # Per language, which wins over `default`: fr: [replacements, numbers]
      #
      # A prompt can be a stage, and any stage can carry a condition — on the
      # text with `when:` / `unless:`, or on the app you dictated into:
      #
      #   - stage: numbers
      #     app: /term|ghostty/          # only in a terminal
      #   - prompt: prose
      #     app: /^(?!.*term)/           # everywhere but; no not_app, the
      #                                  # negation goes in the pattern
      #
      # See docs/pipelines.md.
      pipelines:
        default:
          - replacements
          - fuzzy
          - numbers
          # "read user dot name" -> read user.name in a terminal, and
          # `user.name` in a chat window. Both steps are here and both
          # conditions are read; at most one matches. Anywhere else — a mail
          # window, a document — the sentence is left as spoken.
          - transform: dotted
            app: /term|ghostty|warp|kitty|alacritty|hyper/
          - transform: dotted-chat
            app: /slack|discord/

      # The spelling you want, and the ways it comes out wrong. Whole words,
      # case-insensitive. A source in /slashes/ is a regular expression, and an
      # empty target deletes rather than substitutes — which is how filler
      # words go. With a regex source the target is a template, so $1 writes
      # back what the pattern captured.
      #
      #   Supabase: [super base, superbees]
      #   "": ['/[,]?\\s*\\b(?:u+m+|u+h+|erm+|hmm+)\\b[,]?/']
      #   $1.$2: ['/\\b(\\w+) dot (\\w+)\\b/']   # "user dot name" -> user.name
      #
      # That last one joins any two words either side of "dot", prose included
      # — a pattern cannot tell your code from your sentence. Put it in a
      # pipeline behind `app:` if you only mean it in a terminal.
      replacements: {}



    # The local Ollama model behind spoken commands. Without it dictation still
    # works and every `prompt:` transform below stops.
    llm:
      enabled: true
      model: gemma4:e4b
      endpoint: http://localhost:11434
      # Pin the model in RAM at launch. Ollama otherwise drops it after five
      # minutes and the next command waits 7-10s for the reload. Turn off to
      # get those seconds back as free RAM.
      keep_loaded: true

    # What the activation phrase can reach, and what a pipeline can name.
    #
    #     "hey parrot, make that a bullet list"
    #
    # A description is not a comment — it is what the router matches your words
    # against, so write it the way you would say it. The whole instruction then
    # reaches the prompt, which is why one entry covers "format those dates
    # ISO" and "format those dates with slashes".
    #
    # An entry has either `prompt:`, which asks the local model and costs about
    # a second, or `replace:`, a substitution table of its own that costs
    # nothing:
    #
    #   - name: dotted
    #     description: spoken dotted paths as code
    #     replace:
    #       $1.$2: ['/\\b(\\w+) (?:dot|point) (\\w+)\\b/']
    #
    # A table is not reached by voice — it runs from a pipeline, which is where
    # it can be scoped to one app. Two tables with the same pattern and
    # different output are how "user dot name" becomes user.name in a terminal
    # and `user.name` in chat. See docs/pipelines.md.
    #
    # Results are shown before they replace your selection; add
    # `confirm: false` to one you have come to trust.
    #
    # Fixing a misheard name is built in and does not appear here — run
    # --check-config to see everything the phrase reaches.
    transforms:
      - name: bullets
        description: turn text into a short bullet list
        prompt: |
          Rewrite the text as concise bullets, one idea each.
          Keep the speaker's wording. Return only the bullets.

      - name: terse
        description: shorten text without losing anything it says
        prompt: |
          Cut this down. No filler, same facts, same voice.
          Return only the shortened text.

      - name: grammar
        description: fix grammar and punctuation mistakes, not formatting or numbers
        prompt: |
          Correct grammar, spelling and punctuation. Make the smallest change
          that makes the text correct — and make it. Every error is fixed.
          Nothing else is touched.

          Fix: subject-verb agreement, verb forms, confused homophones
          (its/it's, their/they're, weather/whether), missing or wrong
          punctuation, a missing capital at the start of a sentence, and a
          missing full stop at the end.

          Never reword, reorder, shorten, expand, or improve. Never add or
          remove words except where grammar requires it. Never add quotation
          marks, emphasis, or punctuation the sentence does not need. Keep the
          speaker's own vocabulary, register and phrasing, including informal,
          blunt or repetitive wording. A sentence that is already correct comes
          back exactly as it was.

          A phrase before the main clause takes a comma after it. A trailing
          please or thanks does not.

          Return only the text.

      # The two tables the pipeline above names. Same pattern, different output:
      # that is the whole reason a table has a name.
      #
      # The pattern reads "a word, then dot or point, then a word" — and then
      # refuses it when either side is a word code does not use there. Without
      # that, "voilà le point sur les tests" becomes "voilà le.sur les tests":
      # "point" is an everyday French word and "dot com" is an English one. The
      # first list is what may not come before, the second what may not come
      # after — determiners, prepositions, and the heads of set phrases like
      # "point final" or "dot product".
      #
      # 45/45 on tests/dotted-cases.txt, plus two it cannot do: two ordinary
      # words either side ("réunion point hebdomadaire") is a shape only a
      # dictionary would tell from code. Both are unlikely in a terminal or a
      # chat window, which is the only reason this is on by default. Score it
      # with scripts/check-dotted.sh — it reads the pattern from this file.
      #
      # The second word is matched but not consumed, so a chain still works:
      # "user point profile point name" -> user.profile.name.
      - name: dotted
        description: spoken dotted paths as code
        replace:
          '$1.': ['/\\b(?!(?:le|la|les|l|un|une|des|du|de|d|ce|cet|cette|ces|mon|ma|mes|ton|ta|tes|son|sa|ses|notre|nos|votre|vos|leur|leurs|au|aux|à|quel|quelle|chaque|autre|même|premier|première|deuxième|dernier|dernière|seul|seule|bon|bonne|mauvais|certain|tel|telle|quelque|the|a|an)\\b)(\\w+) (?:dot|point) (?!(?:de|du|des|d|le|la|les|l|un|une|sur|dans|en|et|ou|que|qui|où|à|au|aux|pour|par|avec|sans|est|sont|était|sera|me|te|se|ne|n|c|il|elle|je|tu|nous|vous|ils|elles|ce|plus|moins|très|mais|donc|car|si|comme|final|finale|barre|virgule|commun|commune|faible|faibles|fort|forts|mort|culminant|névralgique|chaud|sensible|positif|négatif|clé|focal|nommé|com|net|org|matrix|product|notation|plot)\\b)(?=\\w)/']

      - name: backticks
        description: wrap dotted paths in backticks, for chat
        replace:
          '`$1`': ['/\\b([A-Za-z_]\\w*(?:\\.[A-Za-z_]\\w*)+)/']

    # Do what was asked even when no prompt above matches:
    #
    #     "hey parrot, use the 24 hour clock"
    #     "hey parrot, sort that list alphabetically"
    #
    # A remark that was never an instruction is still refused, and you see
    # every result before it replaces anything. Turn off to go back to a fixed
    # menu of prompts.
    free_form: true
    """
    }
}

// MARK: - Live reload

/// Watches a single file and fires `onChange` when it is written to.
///
/// Re-arms itself after each event because editors typically replace the file
/// (atomic save) rather than writing in place, which invalidates the descriptor.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit { stop() }

    private func start() {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Atomic save: the inode we were watching is gone. Re-open shortly.
                self.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.start()
                    self.onChange()
                }
            } else {
                self.onChange()
            }
        }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        self.source = source
        source.resume()
    }

    private func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }
}
