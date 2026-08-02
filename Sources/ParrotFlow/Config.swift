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
    var updates: UpdatePolicy = UpdatePolicy()
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
        case hotkey, audio, feedback, transcription, llm, transforms, prompts, updates
        case freeForm = "free_form"
    }

    /// One entry of `transforms:` as it is written, before it is known to be
    /// valid. `content:` is accepted alongside `prompt:` because that is what
    /// `prompts:` has always called it, and moving a section should not mean
    /// renaming a key inside every entry of it.
    private struct TransformEntry: Decodable {
        var name = ""
        var description = ""
        var display = ""
        var confirm = true
        var body: Transform.Body?
        var directory: URL?
        var timeout: Double?
        /// More than one of `prompt:`, `replace:` and `command:` on one entry.
        var namesBoth = false

        enum CodingKeys: String, CodingKey {
            case name, description, display, confirm, prompt, content, replace, command
            case timeout = "timeout_seconds"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func trimmed(_ key: CodingKeys) throws -> String {
                (try c.decodeIfPresent(String.self, forKey: key) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            name = try trimmed(.name)
            description = try trimmed(.description)
            display = try trimmed(.display)
            directory = decoder.userInfo[.configDirectory] as? URL
            confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? true
            timeout = try c.decodeIfPresent(Double.self, forKey: .timeout)

            let instructions = try trimmed(.prompt).isEmpty ? trimmed(.content) : trimmed(.prompt)
            let table = try c.decodeIfPresent([String: [String]].self, forKey: .replace)
            let command = try trimmed(.command)
            namesBoth = [!instructions.isEmpty, table != nil, !command.isEmpty]
                .filter { $0 }.count > 1
            if !command.isEmpty {
                body = .command(command)
            } else if let table {
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
                Log.write(
                    "transforms: \"\(entry.name)\" names more than one of "
                    + "`prompt:`, `replace:` and `command:`; skipped"
                )
                continue
            }
            guard let body = entry.body else {
                Log.write(
                    "transforms: \"\(entry.name)\" has none of "
                    + "`prompt:`, `replace:` or `command:`; skipped"
                )
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
                display: entry.display,
                directory: entry.directory, timeout: entry.timeout,
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
        /// What goes on screen while this runs — "Formatting functions…",
        /// "Fixing grammar…".
        ///
        /// Not the description. The description is written for the router, in
        /// the words you would say to ask for this; a display is written for
        /// you, in the words that make a paused menu bar legible. A pipeline
        /// stage is the case that needs it: nothing on screen ever said which
        /// of them the second you are waiting on belongs to.
        ///
        /// Empty means say nothing, which is right for a table — it finishes
        /// before the label could be read, and a flash nobody can read is
        /// worse than no flash at all.
        var display: String = ""
        /// The directory of the file that declared this transform, which is
        /// what a relative `command:` is relative to. Nil when it was not
        /// decoded from a file — a default, or a test.
        var directory: URL?
        /// How long a `command:` may take before the transcript is let through
        /// untouched. Nil means `CommandRunner.timeout`, which is two seconds.
        ///
        /// Two seconds is right for a script and wrong for one that asks a
        /// model: Ollama takes 7–10s when the weights have to come back off
        /// disk, so the first correction after a pause silently did nothing.
        /// Per transform rather than global, because the two live in the same
        /// pipeline and want different answers.
        var timeout: Double?
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
            /// A program to pipe the transcript through: it arrives on stdin
            /// and comes back on stdout.
            ///
            /// The other two bodies can only do what this app already knows
            /// how to do, and every new kind of rewrite meant a new primitive.
            /// Spoken identifiers were going to need case conversion in the
            /// substitution engine; the next thing would need something else.
            /// A command needs nothing: whatever you can write, you can run.
            ///
            /// The cost is that config.yaml now executes code, which
            /// `--check-config` says out loud.
            case command(String)
        }

        var isPrompt: Bool {
            if case .prompt = body { return true }
            return false
        }

        var isTable: Bool {
            if case .replace = body { return true }
            return false
        }

        /// The display as it goes on screen, or nil when none was written.
        ///
        /// The ellipsis is added rather than asked for. Every other waiting
        /// message in the app ends in one — "Transcribing…", "Thinking…" —
        /// and a config that has to remember the punctuation is one where
        /// half the entries eventually do not.
        var displayLabel: String? { Self.label(display) }

        static func label(_ display: String) -> String? {
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.hasSuffix("…") || trimmed.hasSuffix("...")
                ? trimmed : trimmed + "…"
        }

        /// The prompt-shaped view of this transform, for everything that
        /// already speaks `Prompt` — the router, `PromptRunner`, the panels.
        var asPrompt: Prompt? {
            guard case .prompt(let content) = body else { return nil }
            return Prompt(
                name: name, description: description, content: content,
                display: display, confirm: confirm
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
        /// What goes on screen while this runs — see `Transform.display`.
        var display: String = ""
        /// Show the result and wait for you before replacing anything.
        ///
        /// On by default: a transform overwrites text you selected, triggered
        /// by voice, with no dialog in the way. Turn it off per prompt once
        /// that prompt has earned it.
        var confirm: Bool = true

        enum CodingKeys: String, CodingKey {
            case name, description, content, display, confirm
        }

        init(
            name: String, description: String, content: String,
            display: String = "", confirm: Bool = true
        ) {
            self.name = name
            self.description = description
            self.content = content
            self.display = display
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
            display = (try c.decodeIfPresent(String.self, forKey: .display) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? true
        }

        /// The display as it goes on screen, or the prompt's own name when
        /// nothing was written — which is what this path showed before
        /// `display:` existed, so a config that says nothing loses nothing.
        var progressLabel: String {
            Transform.label(display) ?? "\(name)…"
        }

        /// Where the spoken instruction goes if the prompt asks for it inline.
        static let instructionPlaceholder = "{{instruction}}"

        var wantsInstructionInline: Bool {
            content.contains(Self.instructionPlaceholder)
        }
    }

    /// A local Ollama model, used to interpret spoken commands.
    /// How long a release has to have existed before this Mac will take it.
    ///
    /// Not a polling interval — the check itself is daily. This is a waiting
    /// period, and it is the only defence a one-person project has against its
    /// own release pipeline being taken: a bad release that is noticed and
    /// pulled inside the window is one nobody's app ever offered. See
    /// `Updates` for why that is worth a setting.
    struct UpdatePolicy: Codable, Equatable {
        /// Negative never asks GitHub at all. Zero takes a release the day it
        /// is published. Anything else waits that many days.
        var afterDays: Int = 7

        enum CodingKeys: String, CodingKey {
            case afterDays = "after_days"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let v = try c.decodeIfPresent(Int.self, forKey: .afterDays) { afterDays = v }
        }
    }

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

    /// Decodable and not Encodable, like `Config` itself and for the same
    /// reason: nothing writes a config back out, and `activationPhrase` is a
    /// view over the list rather than storage.
    struct Transcription: Decodable, Equatable {
        var enabled: Bool = true
        /// `paste` types the transcript into the frontmost app (needs
        /// Accessibility). `clipboard` just copies it and lets you paste.
        var insertMode: InsertMode = .paste
        /// Say this instead of dictating, and what follows is an instruction
        /// rather than text. Empty disables it.
        ///
        /// Called `correction_phrase` when the only instruction was fixing a
        /// spelling, and `activation_phrase` when there was only ever one.
        /// Both still read, and either may be written as a single phrase or as
        /// a list — a config in any of the three shapes decodes the same way.
        ///
        /// Several because one phrase cannot be said in every position. "hey
        /// parrot" opens an utterance and reads as nonsense inside one; "by the
        /// way parrot" is the reverse. Empty disables the whole thing.
        var activationPhrases: [String] = ["hey parrot"]

        /// The one to show when a single phrase has to be named — a menu
        /// label, a first-run message. The first is the one to teach.
        var activationPhrase: String { activationPhrases.first ?? "" }
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
            case activationPhrases = "activation_phrases"
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
            // Three spellings, oldest first, so the newest present wins — which
            // is what someone mid-rename would expect. Each accepts a phrase or
            // a list: the shape is not what the rename was about, and refusing
            // `activation_phrase: [a, b]` would be a rule with no reason.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            func phrases<K: CodingKey>(
                _ container: KeyedDecodingContainer<K>, _ key: K
            ) throws -> [String]? {
                if let one = try? container.decodeIfPresent(String.self, forKey: key) {
                    return [one]
                }
                return try container.decodeIfPresent([String].self, forKey: key)
            }
            for found in [
                try phrases(legacy, LegacyKeys.correctionPhrase),
                try phrases(c, CodingKeys.activationPhrase),
                try phrases(c, CodingKeys.activationPhrases),
            ] {
                guard let found else { continue }
                // Blanks would match nothing and cost a comparison per
                // transcript; an all-blank list is how you turn this off.
                activationPhrases = found
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
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
        /// How long the mic stays open after the key comes up, in push-to-talk.
        /// The hand beats the mouth: the last syllable lands after the release.
        var releaseTailSeconds: Double = 0.3

        enum CodingKeys: String, CodingKey {
            case key, modifiers, mode
            case releaseTailSeconds = "release_tail_seconds"
        }

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
            if let tail = try c.decodeIfPresent(Double.self, forKey: .releaseTailSeconds) {
                guard tail >= 0, tail <= 5 else {
                    throw ConfigError.invalidValue(
                        key: "hotkey.release_tail_seconds",
                        value: String(tail),
                        expected: "a delay between 0 and 5 seconds"
                    )
                }
                self.releaseTailSeconds = tail
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
        if let updates = try c.decodeIfPresent(UpdatePolicy.self, forKey: .updates) {
            self.updates = updates
        }
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
        // Said out loud, every time, and not only when something is wrong with
        // it. A `command:` transform is the one thing in this file that runs
        // code rather than describing a rewrite, and a config that executes
        // something you have forgotten about — or that arrived in a config you
        // copied — should not be able to stay quiet about it.
        for transform in transforms {
            guard case .command(let command) = transform.body else { continue }
            // A first word that is still relative after resolution is a bare
            // command name for the shell to find on PATH — `python3`, `sed` —
            // and this cannot say whether that will work. What it can say is
            // that a script sitting right there will not run.
            let wrong = CommandRunner.complaint(about: command, base: transform.directory)
            found.append(
                "transforms: \"\(transform.name)\" runs a program — \(command)"
                + (wrong.map { " — \($0)" } ?? "")
            )
        }
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

extension CodingUserInfoKey {
    // The directory of the file being decoded — see `Transform.directory`.
    // The initialiser only fails on an empty raw value.
    // swiftlint:disable:next force_unwrapping
    static let configDirectory = CodingUserInfoKey(rawValue: "parrotflow.configDirectory")!
}

enum ConfigStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AppVariant.configDirectory, isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("config.yaml")
    }

    /// Where the `code_identifiers` transform's program lives — beside the config
    /// that names it, which is what makes `command: code_identifiers.py` resolve.
    static var codeIdentifiersURL: URL {
        directory.appendingPathComponent("code_identifiers.py")
    }

    /// Creates the config file, and the one program it ships with, if they are
    /// not there yet.
    ///
    /// The script is written rather than bundled because this app has no
    /// resources — `defaultYAML` is a string in the binary for the same reason
    /// — and because a script you can open and edit beside your config is the
    /// point of it. It is never overwritten: once it exists it is yours, and an
    /// update that reverted your stop lists would be the app taking back
    /// something it gave you.
    static func createIfMissing() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: codeIdentifiersURL.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try defaultCodeIdentifiersScript.write(to: codeIdentifiersURL, atomically: true, encoding: .utf8)
            // A shebang does nothing without this.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codeIdentifiersURL.path)
            Log.write("config: wrote \(codeIdentifiersURL.lastPathComponent)")
        }
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try defaultYAML.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// The shipped copy of examples/code_identifiers.py.
    ///
    /// Two copies of one file, which is a thing this repo has been bitten by
    /// twice — so scripts/check-example-script.sh fails when they differ. The
    /// example is the one to edit; this is the one that ships.
    static let defaultCodeIdentifiersScript = #"""
#!/usr/bin/env python3
"""Spoken names as identifiers. A transcript on stdin, the rewrite on stdout.

    transforms:
      - name: code_identifiers
        description: spoken names as identifiers
        display: Formatting identifiers
        command: code_identifiers.py                       # rules only, 0.03s
      # command: code_identifiers.py --model gemma4:e4b     # + the model, below
        timeout_seconds: 12                                 # only with --model

    transcription:
      pipelines:
        default:
          - transform: code_identifiers
            when: /\b(?:function|variable|class|constant|fonction|classe)\b/

"a python function called max retries"  ->  "a python function called max_retries"

The convention comes from the language if one was said, and is camelCase when
none was. A class or a type takes PascalCase whatever the language; a constant
takes SCREAMING_SNAKE_CASE.

A copy of this file is written to ~/.config/parrotflow/code_identifiers.py on
first launch and never overwritten afterwards, and the step above is in the
default pipeline. This one, in examples/, is the copy you read and edit; see
scripts/check-example-script.sh, which keeps the two equal.

Why a script and not a prompt: measured. On tests/code-code-identifier-cases.yaml, 56
cases, this scores 100% and costs a process start; gemma4:e4b scores 68% and
costs a second — and its errors are the expensive kind, capitalising words it
was not asked to touch and translating French names into English. See
scripts/validate-code-identifiers.py for the scoreboard.

--model asks a local model, and only about what the rules declined: a name
given without a marker in front of it — "call it max retries", "rename the
variable to retry count", "a getter for the user profile name". The rules
cannot see those at all, and the model gets 8/8 on them where the rules get
2/8.

It extracts rather than rewrites — the language, and the names — and everything
after that stays here. That division is the whole reason it works: asked to
return the rewritten sentence instead, the same model scored 68% and
capitalised words nobody asked it to touch.

It is off by default, and the trade is measured rather than assumed. Over 75
cases, adding it takes the sentences that should change from 87% to 100% — and
the sentences that must come back untouched from 94% to 84%, because a model
asked only about what a careful rule refused sees mostly near-misses. Turn it
on if you dictate code all day and will notice; leave it off if a sentence
quietly rewritten would slip past you. It also costs about a second, and a
model that is cold takes longer than the two seconds ParrotFlow waits, in which
case your transcript passes through untouched.

It is yours now. The stop lists below are the part that will want editing:
they say where a name ends, and that boundary is a judgement about how you
speak, not a fact.
"""
import json
import re
import sys
import urllib.request

# A name has to be introduced as one. Without this, "i called max yesterday"
# is a naming and the transform renames a person.
KIND = re.compile(
    r"\b(?:function|method|variable|class|constant|type|struct|interface|enum|"
    r"fonction|m[ée]thode|variable|classe|constante)\b", re.I)

# "called by the scheduler" is a passive and never a naming.
TRIGGER = re.compile(
    r"\b(?:called|named|call it|nomm[ée]e?|qui s['’]appelle|appel[ée]e?)\s+"
    r"(?!by\b|par\b)", re.I)

# Where the name stops and the sentence resumes. "in", "from", "on" and "to"
# were here and had to come out — they are ordinary parts of identifiers
# ("is logged in", "build request from config") and stopping there truncated
# the name.
TAIL = re.compile(
    r"\b(?:that|which|for|and|so|should|will|when|if|because|"
    r"qui|que|pour|et|dans|sur|avant|apr[èe]s|doit)\b", re.I)

# The convention each language writes identifiers in. A table rather than a
# pattern, because a pattern has to be edited to learn a language and a table
# has to be added to — and everything it does not know reads as camelCase,
# which was silently wrong for zig, julia, erlang and c# until this was a
# table. Add your own; it is a dict, not a regex.
BY_LANGUAGE = {
    "python": "snake", "rust": "snake", "ruby": "snake", "elixir": "snake",
    "erlang": "snake", "julia": "snake", "perl": "snake", "zig": "snake",
    "nim": "snake", "crystal": "snake", "lua": "snake", "c": "snake",
    "javascript": "camel", "typescript": "camel", "java": "camel",
    "kotlin": "camel", "go": "camel", "swift": "camel", "php": "camel",
    "scala": "camel", "dart": "camel", "groovy": "camel", "haskell": "camel",
    "c#": "pascal", "csharp": "pascal", "f#": "pascal",
}
# "c#" ends in a character no word boundary follows, so the trailing \b would
# never match it — the boundary has to be asserted on the left only, plus "not
# followed by more word characters".
LANGUAGE = re.compile(
    r"\b(" + "|".join(re.escape(name) for name in sorted(BY_LANGUAGE, key=len, reverse=True))
    + r")(?!\w)", re.I)
PASCAL_KIND = re.compile(r"\b(?:class|classe|type|struct|interface|enum)\b", re.I)
SCREAMING_KIND = re.compile(r"\b(?:constant|constante)\b", re.I)


def style_for(sentence, before, language=None):
    """A kind word in front of the name wins — a class is PascalCase in any
    language — then the language, then camelCase for a sentence that named
    none."""
    if SCREAMING_KIND.search(before):
        return "screaming"
    if PASCAL_KIND.search(before):
        return "pascal"
    if not language:
        found = LANGUAGE.search(sentence)
        language = found.group(1) if found else None
    return BY_LANGUAGE.get((language or "").lower(), "camel")


def cased(words, style):
    if style == "snake":
        return "_".join(word.lower() for word in words)
    if style == "screaming":
        return "_".join(word.upper() for word in words)
    if style == "pascal":
        return "".join(word.capitalize() for word in words)
    return words[0].lower() + "".join(word.capitalize() for word in words[1:])


def convert(text):
    out = text
    # Right to left, so an earlier rewrite cannot move a later match.
    for match in list(TRIGGER.finditer(text))[::-1]:
        if not KIND.search(text[:match.start()]):
            continue
        rest = text[match.end():]
        stop = TAIL.search(rest)
        span = (rest[:stop.start()] if stop else rest).strip()
        words = [word for word in re.split(r"[^\w'’]+", span) if word]
        # One word is already an identifier, whatever its case.
        if len(words) < 2:
            continue
        # Nobody dictates a five-word identifier, and prose runs on: "the class
        # called intro to python starts at nine tomorrow" is not a naming, and
        # the length is what says so. Declining rather than truncating — a
        # shortened guess is a wrong rewrite, and this is a stage that runs on
        # sentences nobody asked it to touch.
        if len(words) > 4:
            continue
        if span in out:
            out = out.replace(span, cased(words, style_for(text, text[:match.start()])), 1)
    return out


# The prompt, iterated and scored as v5 in scripts/validate-code-identifiers.py.
#
# It extracts rather than rewrites: the language once, the names one per line.
# Everything after that is code — the language becomes a convention through
# BY_LANGUAGE above, a kind word still overrides it for a class or a constant,
# and putting the words back is a string replace.
#
# Asking for the language rather than pattern-matching it is what makes the
# table extensible without touching the prompt, and it is why the model is
# still worth asking once the table exists: a sentence can name a language in a
# way no scan of it will catch.
PROMPT = """\
The text is a dictated sentence. Some of them give names to functions, \
variables, classes or constants.

Reply in exactly this shape and nothing else:

lang: <the programming language the sentence names, or none>
name: <the words of one name, copied exactly>

Repeat the name line once per name. Write no name line at all when the \
sentence names nothing.

- Copy the words exactly as they appear. Do not rewrite them, join them or \
change their case — that is done elsewhere.
- A name is two to four words. Take the whole name and only the name.
- The name may be given without the word "called": "call it X", "rename it to \
X", "a getter for X".
- Write no name line when the sentence merely talks about a function, a class \
or a variable, or is about something else entirely.

text: add a rust function called read config file
lang: rust
name: read config file

text: call it max retries in python
lang: python
name: max retries

text: a python function called read config and a variable called config path
lang: python
name: read config
name: config path

text: the retry count is too high and it hammers the api
lang: none

text: we talked about python packaging for most of the afternoon
lang: python

text: there is a method called cognitive behavioural therapy for that
lang: none
"""


def ask(model, text, endpoint="http://localhost:11434"):
    """The model's answer, or "" for every way this can fail. Ollama not
    running is an ordinary state and a transcript is not worth dropping."""
    body = {"model": model, "system": PROMPT, "prompt": text, "stream": False,
            "think": False, "options": {"temperature": 0, "num_predict": 64}}
    request = urllib.request.Request(
        endpoint + "/api/generate", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return (json.load(response).get("response") or "").strip()
    except Exception:
        return ""


def place(reply, text):
    """The extraction applied — the deterministic half, sharing `cased` and
    `style_for` with the rules above so there is one algorithm and not two."""
    language, names = None, []
    for line in reply.splitlines():
        line = line.strip()
        if line.lower().startswith("lang:"):
            said = line.split(":", 1)[1].strip().lower()
            language = None if said in ("none", "") else said
        elif line.lower().startswith("name:"):
            names.append(line.split(":", 1)[1].strip())

    out = text
    for span in names:
        span = span.strip().strip('".')
        words = [word for word in re.split(r"[^\w'’]+", span) if word]
        # The same guards the rules use: a name is two to four words, and the
        # model does not get to invent words that are not in the sentence.
        if len(words) < 2 or len(words) > 4 or span.lower() not in out.lower():
            continue
        start = out.lower().index(span.lower())
        out = (out[:start] + cased(words, style_for(out, out[:start], language))
               + out[start + len(span):])
    return out


if __name__ == "__main__":
    model = None
    if "--model" in sys.argv:
        index = sys.argv.index("--model")
        model = sys.argv[index + 1] if len(sys.argv) > index + 1 else None

    text = sys.stdin.read().rstrip("\n")
    out = convert(text)
    # The model is asked only about what the rules declined. On a sentence with
    # a marker in it — the common case — nothing is paid at all.
    if model and out == text:
        out = place(ask(model, text), text)
    sys.stdout.write(out)
"""#

    /// Reads and decodes the config. Missing keys fall back to the struct defaults.
    static func load() throws -> Config {
        try createIfMissing()
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Config()
        }
        // A relative `command:` is relative to the file that declared it, so a
        // config carries its scripts beside it and a `--pipeline` fixture
        // carries its own.
        return try YAMLDecoder().decode(
            Config.self, from: text, userInfo: [.configDirectory: directory]
        )
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

      # How long the mic stays open after you let go, in push_to_talk. The hand
      # is faster than the mouth and the last syllable arrives after the key is
      # up; without this it is cut off. 0 turns it off.
      release_tail_seconds: 0.3

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

      # Say one of these instead of dictating and what follows is an
      # instruction: "hey parrot, make that a bullet list". An empty list
      # disables spoken commands.
      #
      # One of them mid-sentence turns the rest into an instruction about the
      # words before it, in the same breath:
      #
      #   "there is a bug in get username by the way parrot format that name"
      #
      # which is why there are two: "hey parrot" opens an utterance and reads
      # as nonsense inside one, and "by the way parrot" is the reverse. The
      # first is the one to teach someone.
      activation_phrases: [hey parrot, by the way parrot]

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
          # "read user dot name" -> read user.name, wherever you write
          # code-ish text. Anywhere else — a mail window, a document — the
          # sentence is left exactly as spoken.
          #
          # `backticks` below would wrap it for chat, and is deliberately not
          # in this list. Slack's composer converts markdown as you type it
          # and never re-reads text that arrives by paste, so the backticks
          # land in your message as characters. Add the step if your chat app
          # renders pasted markup.
          - transform: dotted
            app: /term|ghostty|warp|kitty|alacritty|hyper|slack|discord/
          # "a python function called max retries" -> ...called max_retries, in
          # the convention of the language you named. Same places as `dotted`,
          # and `when:` keeps it from starting a process on a sentence that
          # names nothing — which is most of them. See examples/code_identifiers.py,
          # written beside this file on first launch and yours to edit.
          - transform: code_identifiers
            app: /term|ghostty|warp|kitty|alacritty|hyper|code|cursor|zed|xcode|jetbrains|idea|pycharm|webstorm/
            when: /\\b(?:function|method|variable|class|constant|type|struct|interface|enum|fonction|méthode|classe|constante)\\b/
          # `email` and `slack` below lay dictated prose out for one kind of
          # window each, and are deliberately not in this list. Every stage
          # here is free and needs nothing running; those two cost about a
          # second and stop dead without Ollama, which is not a default. Wire
          # them up behind `app:` when you want them — config.example.yaml
          # shows how.

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

    # Checking whether a newer ParrotFlow exists.
    #
    # One call a day to GitHub's release API — no account, nothing about you, and
    # nothing about what you dictate. It is the only request this app makes on its
    # own; the speech model is fetched once on first use, and the language model
    # never leaves your Mac.
    #
    # The number is a waiting period, not how often it looks:
    #
    #   -1   never ask at all
    #    0   offer a release the day it is published
    #    7   only offer a release that has existed for a week
    #
    # The wait is the point. A release that turns out to be bad — a pipeline taken,
    # a key stolen — is one that gets noticed and pulled, and a week of distance
    # means your Mac never saw it. What proves an archive is ours is the pinned
    # signing certificate in scripts/install.sh; this is the other half, and buys
    # the time someone needs to notice in the first place.
    updates:
      after_days: 7

    # What the activation phrase can reach, and what a pipeline can name.
    #
    #     "hey parrot, make that a bullet list"
    #
    # A description is not a comment — it is what the router matches your words
    # against, so write it the way you would say it. The whole instruction then
    # reaches the prompt, which is why one entry covers "format those dates
    # ISO" and "format those dates with slashes".
    #
    # An entry has one of three bodies. `prompt:` asks the local model and
    # costs about a second. `replace:` is a substitution table of its own and
    # costs nothing. `command:` runs a program of yours — the transcript on
    # stdin, the rewrite on stdout — and costs a process start:
    #
    #   - name: dotted
    #     description: spoken dotted paths as code
    #     replace:
    #       $1.$2: ['/\\b(\\w+) (?:dot|point) (\\w+)\\b/']
    #
    #   - name: code_identifiers
    #     description: spoken names as identifiers
    #     command: code_identifiers.py          # beside this file; see examples/
    #
    # A `command:` is the one thing in this file that runs code rather than
    # describing a rewrite. --check-config names every one of them out loud. A
    # command that fails, says nothing, or takes more than two seconds leaves
    # the transcript exactly as it arrived.
    #
    # A table is not reached by voice — it runs from a pipeline, which is where
    # it can be scoped to one app. Two tables with the same pattern and
    # different output are how "user dot name" becomes user.name in a terminal
    # and `user.name` in chat. See docs/pipelines.md.
    #
    # `display:` is what the menu bar says while an entry runs — "Fixing
    # grammar…", "Formatting identifiers…". The description is written for the
    # router, in the words you would say; a display is written for you, for the
    # second you spend watching nothing happen. The ellipsis is added for you.
    # Leave it off a table, which finishes before the label could be read.
    #
    # Results are shown before they replace your selection; add
    # `confirm: false` to one you have come to trust.
    #
    # Fixing a misheard name is built in and does not appear here — run
    # --check-config to see everything the phrase reaches.
    transforms:
      - name: bullets
        description: turn text into a short bullet list
        display: Making bullets
        prompt: |
          Rewrite the text as concise bullets, one idea each.
          Keep the speaker's wording. Return only the bullets.

      - name: terse
        description: shorten text without losing anything it says
        display: Cutting it down
        prompt: |
          Cut this down. No filler, same facts, same voice.
          Return only the shortened text.

      - name: grammar
        description: fix grammar and punctuation mistakes, not formatting or numbers
        display: Fixing grammar
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

      # Two prompts scoped to one kind of window each. `grammar` mends a
      # sentence; these two also lay one out — a greeting on its own line, a
      # blank line where the subject changes — which is the part no
      # substitution can express and the reason they are prompts.
      #
      # Both are told twice not to write anything, because that is the failure
      # that costs you something: a model handed a dictated email will gladly
      # return a better one, in its own voice, and you will not notice until it
      # has gone.
      #
      # 8/10 on gemma4:e4b, and the six versions before it are written down in
      # config.example.yaml beside the same prompt. The short version: a
      # prohibition ("do not invent a greeting") read as a topic and produced
      # one; "nothing is ever deleted" produced a literal "[Signature]";
      # worked examples for the greeting came back in the output; and the list
      # rule has to sit with the paragraph rule, because after the short-reply
      # clause it turned a two-word reply into "[No body text]".
      #
      # The two still failing are one shape — a short reply ending in a goodbye
      # comes back as the goodbye alone. Numbered lists are deliberately absent:
      # the version that forced them from spoken ordinals dropped an item.
      - name: email
        description: lay dictated text out as an email
        prompt: |
          Lay the text out as an email, in the language it was dictated in.
          Fix the writing; do not write it.

          Correct grammar, spelling and punctuation, and drop the hesitations
          — um, uh, euh, well, you know, I mean. Every other word survives:
          the wording, the order and the tone are the speaker's.

          If the text opens with a greeting, it goes on its own line, with a
          comma after it and a blank line under it. If it does not, the email
          starts with the first sentence. Never add a greeting nobody spoke.

          Break the body into paragraphs where the subject changes, a blank
          line between them. Add no headings and no emphasis.

          Three or more things listed in a row never stay inline. Whatever
          joined them — commas, "and", nothing at all — the words introducing
          them take a colon and each thing goes on a line of its own behind a
          dash. No number has to be said for this: "here is what I need from
          you", "the steps are", "we should" all open a list as surely as
          "there are three things" does. Two things are a sentence and stay
          one.

          A name at the end is a signature: a blank line, then the name on
          its own line, and a closing word said just before it — thanks,
          merci — on the line above. No name at the end means no signature:
          the last thing said is the last line of the body, wherever it
          sounds like a goodbye.

          A short reply is not an email with parts. One or two sentences and
          no hello in front of them come back as one or two sentences,
          corrected, with no line put anywhere.

          Return only the email.

      # 3/3. "Add nothing" rather than "no greeting, no sign-off": the second
      # wording read as an instruction to remove one, and "hey uh quick one the
      # build is red" came back as "The build is red". The slang line is there
      # because "gonna" was being corrected to "going to", which is the
      # speaker's voice going out with the hesitations.
      - name: slack
        description: tidy dictated text into a chat message
        prompt: |
          Tidy the text into a chat message, in the language it was dictated
          in. Fix the writing; do not write it.

          Correct grammar, spelling and punctuation, and drop the hesitations
          — um, uh, euh, well, you know, I mean. Every other word survives.
          Slang and contractions are the speaker's voice rather than
          mistakes: gonna stays gonna, ouais stays ouais.

          Add nothing: no greeting, no sign-off, no heading, no bullet, no
          bold, no backtick. Slack's composer renders none of that when text
          arrives by paste, so it would land in the message as characters.
          Remove nothing either: a spoken "hey" is part of the message.

          One paragraph, unless the text plainly holds two.

          Return only the message.

      # Two tables rather than one prompt, and the marker word is why they can be.
      #
      # A name is a lookup. The prompt that used to do this got to 6/6 after four
      # rewrites, and its first draft answered "Sofia already looked at it" with
      # "@priya already looked at it" — a handle invented for a name it had never
      # been given, which in Slack is a message sent to the wrong person. A table
      # cannot do that. It substitutes what is in it, leaves the rest alone, costs
      # nothing, and needs no model running.
      #
      # `mention` is the safety, not the syntax. Without a marker the table would
      # turn every "Marie" into a ping, and a message that names someone is not a
      # message that pings them. It is said in the same breath, so unlike the voice
      # command this replaces it costs no round trip:
      #
      #     "mention marie can you look at this"
      #     -> "@marie.dupont can you look at this"
      #
      # Two tables and not one, so the group pings can go without the handles going
      # with them: those are the two that wake people up, and @channel reaches the
      # ones who are away.
      #
      #
      # The marker has to open the message or follow a pause, and that is the half
      # of the safety the first version of this table did not have. "mention" is an
      # ordinary English verb: "I should mention here that the deadline changed"
      # came back as "I should @here that the deadline changed", and "I wanted to
      # mention Marie is off next week" pinged Marie. Neither is a message anyone
      # meant to send, and a pipeline stage has no preview to catch it — it runs on
      # a transcript nobody has seen yet.
      #
      # So the word counts only at the start of the utterance or straight after
      # . ! ? ; or a comma, which is where it lands when you mean it and almost
      # never where the verb does. Same shape as the stop lists on `dotted`, for
      # the same reason: that pattern has to tell code from prose, this one has to
      # tell an instruction from a verb. The cost is that "can you mention marie
      # about the invoice" does nothing — a ping you did not get rather than one
      # you did not mean, which is the direction to fail in.
      # To fill this in, hand Claude Code your team's names and handles and ask it
      # to update this table. The shape is regular and the names are yours.
      - name: slack_handles
        description: spoken names as Slack handles
        replace:
          '$1@marie.dupont': ['/(^|[.!?;,]\\s*)mention(?:ne)? marie\\b/']
          '$1@tleroy': ['/(^|[.!?;,]\\s*)mention(?:ne)? thomas\\b/']
          '$1@priya': ['/(^|[.!?;,]\\s*)mention(?:ne)? priya\\b/']

      - name: slack_mentions
        description: spoken group mentions as @here and @channel
        replace:
          '$1@here': ['/(^|[.!?;,]\\s*)mention(?:ne)? (?:everyone here|here)\\b/']
          '$1@channel': ['/(^|[.!?;,]\\s*)mention(?:ne)? (?:the )?(?:whole )?channel\\b/']

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

      # A program rather than a table, because casing words is not something a
      # substitution can express. The transcript reaches it on stdin and comes
      # back on stdout; a relative path is beside this file. Written there on
      # first launch, and yours — the stop lists in it decide where a name
      # ends, which is a judgement about how you speak.
      - name: code_identifiers
        description: spoken names as identifiers
        display: Formatting identifiers
        command: code_identifiers.py
        # Add `--model gemma4:e4b` to have a model handle the namings the rules
        # cannot see — "call it max retries", "rename the variable to retry
        # count". Measured over 75 cases: it takes the sentences that should
        # change from 88% to 100%, and the ones that must come back untouched
        # from 94% to 84%, because a model asked only about what a careful rule
        # refused sees mostly near-misses. Off by default for that reason, and it
        # costs about a second.
        #
        # Raise `timeout_seconds` with it. A command has two seconds before the
        # transcript is let through untouched, which is right for a script and
        # wrong for one that asks Ollama: a model whose weights have gone back to
        # disk takes 7-10s, so the first correction after a pause would silently
        # do nothing.
        # timeout_seconds: 12

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
