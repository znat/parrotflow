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
        /// Say this instead of dictating to open the correction panel for the
        /// text you have selected. Empty disables it.
        var correctionPhrase: String = "hey parrot"
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
            case enabled, vocabulary, replacements, languages
            case insertMode = "insert_mode"
            case correctionPhrase = "correction_phrase"
            case rewriteLine = "rewrite_line"
        }
        /// Words the model would otherwise never produce — see `VocabularyTerm`.
        var vocabulary: [VocabularyTerm] = []
        /// Applied after transcription, last. A blunt instrument: use it only
        /// for terms that can't collide with something you might really say.
        var replacements: [String: String] = [:]

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
            if let phrase = try c.decodeIfPresent(String.self, forKey: .correctionPhrase) {
                self.correctionPhrase = phrase
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
            if let vocabulary = try c.decodeIfPresent([VocabularyTerm].self, forKey: .vocabulary) {
                self.vocabulary = vocabulary
            }
            if let replacements = try c.decodeIfPresent([String: String].self, forKey: .replacements) {
                self.replacements = replacements
            }
        }
    }

    /// A term to bias recognition toward.
    ///
    /// `aliases` are what the *spotter* listens for and `text` is what gets
    /// written, which is the whole trick for a name whose spelling doesn't
    /// match its sound: list the phonetic renderings an ASR would actually
    /// produce, and get back the spelling you want.
    ///
    /// Accepts either form in YAML:
    ///
    ///     vocabulary:
    ///       - Parakeet
    ///       - text: Zylbersztejn
    ///         aliases: [Zilbershtayn, Silbershtein]
    struct VocabularyTerm: Codable, Equatable {
        var text: String
        var aliases: [String] = []

        // Not synthesized: this type defines both init(from:) and encode(to:).
        enum CodingKeys: String, CodingKey {
            case text, aliases
        }

        init(text: String, aliases: [String] = []) {
            self.text = text
            self.aliases = aliases
        }

        init(from decoder: Decoder) throws {
            // Bare string form.
            if let single = try? decoder.singleValueContainer(),
               let text = try? single.decode(String.self) {
                self.init(text: text)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let text = try c.decode(String.self, forKey: .text)
            let aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
            self.init(text: text, aliases: aliases)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(text, forKey: .text)
            if !aliases.isEmpty { try c.encode(aliases, forKey: .aliases) }
        }
    }

    struct Hotkey: Codable, Equatable {
        /// Key name understood by `KeyCodes.code(for:)`, e.g. "space", "d", "f13".
        var key: String = "right_option"
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
        var outputDir: String = "~/Recordings/ParrotFlow"
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
    }

    var resolvedOutputDir: URL {
        URL(fileURLWithPath: (audio.outputDir as NSString).expandingTildeInPath)
    }
}

// MARK: - Loading

enum ConfigStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/parrotflow", isDirectory: true)
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

    static let defaultYAML = """
    # ParrotFlow configuration
    # Edit and save — changes are picked up automatically.

    hotkey:
      # Either a bare modifier used on its own:
      #   right_option, left_option, right_command, left_command,
      #   right_control, left_control, right_shift, left_shift, fn
      # ...or a character key plus modifiers:
      #   a-z, 0-9, space, return, tab, escape, f1-f20, arrows,
      #   comma, period, slash, semicolon, quote, backslash,
      #   leftbracket, rightbracket, minus, equal, grave, delete
      key: right_option

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
      output_dir: ~/Recordings/ParrotFlow
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

      # Acoustic context biasing. Off by default: it fires on audio that
      # contains nothing like the term and deletes the words it lands on.
      # See docs/transcription.md before enabling, and verify with --spot.
      vocabulary: []

      # Last-resort literal swaps, applied after boosting. Word-boundary
      # matched and case-insensitive.
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
    """
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
