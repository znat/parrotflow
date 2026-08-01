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
struct Config: Codable, Equatable {
    var hotkey: Hotkey = Hotkey()
    var audio: Audio = Audio()
    var feedback: Feedback = Feedback()
    var transcription: Transcription = Transcription()
    var llm: LLM = LLM()
    var prompts: [Prompt] = []

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
        case hotkey, audio, feedback, transcription, llm, prompts
        case freeForm = "free_form"
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
        /// keys and retype it. Destructive if the guesses are wrong, so it is
        /// opt-in and only fires when the line is recognisably one we wrote.
        var rewriteLine: Bool = false
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

        /// One rule per mishearing, flattened for the substitution pass.
        var rules: [Rule] {
            replacements.flatMap { target, sources in
                sources.map { Rule(source: $0, replacement: target) }
            }
        }

        /// A single substitution.
        ///
        /// A source wrapped in slashes is a regular expression, which is how
        /// filler words are removed — they need alternation and have to take
        /// their surrounding punctuation with them. Everything else is matched
        /// literally on word boundaries.
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
            if let raw = try c.decodeIfPresent([String: [String]].self, forKey: .pipelines) {
                for (language, names) in raw {
                    let stages = names.compactMap { name -> Pipeline.Stage? in
                        guard let stage = Pipeline.stage(named: name) else {
                            unknownStages.append(name)
                            return nil
                        }
                        return stage
                    }
                    pipelines[language.lowercased()] = Pipeline(stages: stages)
                }
            }
            for key in [LegacyKeys.numbers, .fuzzyMatching] {
                if (try? legacy.decodeIfPresent(Bool.self, forKey: key)) ?? nil != nil {
                    retired.append(key.stringValue)
                }
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
        if let prompts = try c.decodeIfPresent([Prompt].self, forKey: .prompts) {
            // A prompt missing a name or content cannot be routed to or run, and
            // dropping it silently is how a typo becomes an evening. Named here
            // rather than thrown, so one bad entry doesn't cost you the others.
            self.prompts = prompts.filter { prompt in
                guard !prompt.name.isEmpty, !prompt.content.isEmpty else {
                    Log.write("prompts: skipped an entry missing a name or content")
                    return false
                }
                if prompt.description.isEmpty {
                    Log.write("prompts: \"\(prompt.name)\" has no description; the router cannot pick it")
                }
                return true
            }
        }
        if let freeForm = try c.decodeIfPresent(Bool.self, forKey: .freeForm) {
            self.freeForm = freeForm
        }
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
    # Edit and save — changes are picked up automatically.

    hotkey:
      # Either a bare modifier used on its own:
      #   right_option, left_option, right_command, left_command,
      #   right_control, left_control, right_shift, left_shift, fn
      # ...or a character key plus modifiers:
      #   a-z, 0-9, space, return, tab, escape, f1-f20, arrows,
      #   comma, period, slash, semicolon, quote, backslash,
      #   leftbracket, rightbracket, minus, equal, grave, delete
      key: \(AppVariant.defaultHotkey)

      # Any of: command, control, option, shift (aliases: cmd, ctrl, alt, opt).
      # Required for a character key; ignored for a bare modifier.
      modifiers: []

      # toggle       -> tap to start, tap again to stop
      # push_to_talk -> record only while the key is held
      #
      # Bare modifiers want push_to_talk: on toggle, Right Option would start
      # recording every time you typed an accented character with it.
      mode: push_to_talk

    audio:
      # 16 kHz mono is what Parakeet wants. Leave this alone.
      sample_rate: 16000
      output_dir: \(AppVariant.defaultOutputDir)
      # Discard anything shorter than this (seconds)
      min_duration_seconds: 0.3

      # Check for speech before transcribing, and skip clips that have none.
      # Without it a stray hotkey press decodes room tone into "Yeah." or
      # "Thank you for watching". Turn off if it ever swallows real speech.
      speech_gate: true

    feedback:
      sound: true
      overlay: true

    transcription:
      enabled: true

      # paste     -> type it straight into the app you're in (needs Accessibility)
      # clipboard -> just copy it, you press Cmd-V
      insert_mode: paste

      # Select a wrong word anywhere, hold the hotkey and say this, and a panel
      # opens to teach ParrotFlow the right spelling. Needs Accessibility.
      correction_phrase: hey parrot

      # Languages you dictate in, most common first. Not sent to Parakeet — it
      # transcribes multilingually by itself and reports no language back. This
      # is the list ParrotFlow chooses between when working out which language a
      # transcript was in, so naming only what you actually speak makes that
      # more accurate. It picks the correction prompt and the number grammar.
      #
      # The first entry is the fallback, used when a transcript is too short to
      # judge — under four words. Supported: en, fr.
      languages: [en]

      # Everything a finished transcript goes through, in order, per language.
      # A language's own list wins over `default`.
      #
      # Being in a pipeline is the only way a stage runs, so this list is written
      # out with all of them: turning one off means deleting a line you can see,
      # not finding a setting you cannot. Delete `pipelines:` entirely and you get
      # every stage back; write `default: []` and you get none, which is a choice
      # rather than silence.
      #
      # This is written out in full on purpose. The stages are few enough to
      # read at a glance, and deleting a line you can see beats discovering a
      # setting you cannot.
      #
      #   replacements  the substitutions below: literal, word-boundary,
      #                 case-insensitive, or a regex between slashes
      #   fuzzy         the same table, used to catch renderings you have not
      #                 taught — "super bays" reaches Supabase. Only words the
      #                 spell checker does not know are eligible, which is what
      #                 keeps "Excel" from becoming "Vercel". Needs
      #                 `replacements` before it, and says so if it does not
      #                 have one.
      #   numbers       spoken numbers as digits: "two hundred forty-three"
      #                 -> 243, ordinals, decimals, years, spoken digits.
      #                 English and French, chosen per transcript. A number
      #                 word on its own stays a word below ten, so "chapter
      #                 three" is left alone. It does rewrite transcripts that
      #                 were already correct — run --numbers on a line to see
      #                 exactly what it would do before leaving it in.
      pipelines:
        default: [replacements, fuzzy, numbers]

      # Grouped by the spelling you want, listing the ways it gets misheard.
      # Word-boundary matched and case-insensitive.
      #
      #   replacements:
      #     Tasmeen: [Tasmid, Tasmin, Tasmine]
      #
      # A source in /slashes/ is a regular expression, and an empty target
      # deletes rather than substitutes — which is how filler words go:
      #
      #     "": ['/[,]?\\s*\\b(?:u+m+|u+h+|erm+|hmm+)\\b[,]?/']
      replacements: {}



    # A local Ollama model, used to interpret what you say after the wake
    # phrase. Everything still works without it — you just lose spoken
    # commands like "hey parrot, Tasmin spells T A S M E E N".
    llm:
      enabled: true
      model: gemma4:e4b
      endpoint: http://localhost:11434
      timeout_seconds: 20
      # Load the model at launch and keep it there. Ollama otherwise drops it
      # after five minutes, and reloading costs 7-10s on the next correction.
      # Turn off to get those seconds back as free RAM.
      keep_loaded: true

    # Do what was asked even when no prompt matches — which, with no `prompts:`
    # section yet, is everything:
    #
    #     "hey parrot, use the 24 hour clock"
    #     "hey parrot, make sure fifty dollars is formatted as money"
    #     "hey parrot, sort that list alphabetically"
    #
    # A remark that was never an instruction is still refused: the router
    # answers three ways, and separating "an edit nothing covers" from "not an
    # edit at all" is what keeps a passing question away from your selection.
    # You see every result before it replaces anything.
    #
    # Turn it off to go back to a fixed menu of prompts.
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
