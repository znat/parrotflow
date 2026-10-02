import Foundation
import Yams

/// What `config.yaml` may say, key by key: its type, the values it takes, its
/// default and one line of help.
///
/// The parser in `Config.swift` is the truth. Each section here names the
/// `CodingKeys` it mirrors, and `drift()` compares the two, so a key added to
/// the parser without an entry here fails `--schema`.
enum ConfigSchema {

    struct Bounds {
        var min: Double?
        var max: Double?
        var aboveMin = false
    }

    indirect enum Kind {
        case bool
        case integer
        case number
        case range(Bounds)
        case wholeRange(Bounds)
        case text
        case pattern(String)
        /// Read case-insensitively, as every decoder that checks a word does.
        case choice([String])
        /// Sentence marks, as `Language.checked(marks:)` refuses them.
        case marks
        case list(Kind)
        case object(Section)
        /// Any key, each value of this kind: names the user chooses.
        case open(Kind)
        case anything
        case either([Kind])
    }

    struct Field {
        let name: String
        let kind: Kind
        let help: String
        /// JSON-compatible. Nil when absent means something no value can say.
        var fallback: Any?
        /// Still read, and not to be written. The text says what to write instead.
        var deprecated: String?
        var required = false
    }

    struct Section {
        /// The Swift type whose keys these are, for `drift()`.
        let source: String
        let keys: [String]
        let fields: [Field]

        func field(_ name: String) -> Field? {
            fields.first { $0.name == name }
        }
    }

    private static func key(
        _ name: String, _ kind: Kind, _ help: String,
        default fallback: Any? = nil, deprecated: String? = nil, required: Bool = false
    ) -> Field {
        Field(name: name, kind: kind, help: help, fallback: fallback, deprecated: deprecated,
              required: required)
    }

    // MARK: - The table

    static var root: Section {
        Section(source: "Config", keys: Config.CodingKeys.allCases.map(\.stringValue), fields: [
            key("hotkey", .object(hotkey), "The key you hold to dictate."),
            key("audio", .object(audio), "Recording: microphone, speech gate, where clips go."),
            key("feedback", .object(feedback), "Sounds, the pill, and its colours."),
            key("transcription", .object(transcription),
                "How the transcript is inserted, and the passes it runs through."),
            key("models", .open(.object(model)),
                "Every model this config can reach, under a name you choose."),
            key("commands", .object(commands),
                "Which model does each part of \"hey parrot, …\"."),
            key("transforms", .list(.object(transform)),
                "Named rewrites: a prompt, a replace table or a command."),
            key("lists", .open(.list(.text)),
                "Word lists, written once and named. A pattern refers to one as {{name}}."),
            key("updates", .object(updates), "When a new release is offered."),
            key("logging", .object(logging), "What is written to disk about a dictation."),
            key("prompts", .list(.object(transform)),
                "The older name for transforms.",
                deprecated: "the older name for `transforms:`. Still read; move the entries"
                    + " under `transforms:`"),
            key("free_form", .bool, "Replaced by commands.catch_all.",
                deprecated: Config.movedKeys["free_form"]),
            key("llm", .object(llm), "Replaced by models and commands.",
                deprecated: Config.movedKeys["llm"]),
        ])
    }

    static var hotkey: Section {
        Section(source: "Config.Hotkey", keys: Config.Hotkey.CodingKeys.allCases.map(\.stringValue),
                fields: [
            key("key", .text,
                "A bare modifier (right_option, right_command, fn, …) or a character key"
                    + " (a-z, 0-9, f1-f20, space, …). The default differs between the"
                    + " release and dev builds."),
            key("modifiers", .list(.text),
                "For a character key: any of command, control, option, shift (or cmd,"
                    + " ctrl, alt, opt). Ignored for a bare modifier.",
                default: [String]()),
            key("mode", .choice(["push_to_talk", "toggle", "push-to-talk", "pushtotalk",
                                 "ptt", "hold"]),
                "push_to_talk records while held. toggle taps on and off.",
                default: "push_to_talk"),
            key("release_tail_seconds", .range(Bounds(min: 0, max: 5)),
                "Keep recording this long after the key comes up. Push-to-talk only.",
                default: 0.3),
            key("press_delay_seconds", .range(Bounds(min: 0, max: 1)),
                "Hold a bare modifier alone this long before it starts a dictation.",
                default: 0.18),
        ])
    }

    static var audio: Section {
        Section(source: "Config.Audio", keys: Config.Audio.CodingKeys.allCases.map(\.stringValue),
                fields: [
            key("sample_rate", .range(Bounds(min: 8000, max: 192_000)),
                "Parakeet expects 16 kHz mono. Almost never worth changing.",
                default: 16000),
            key("output_dir", .text,
                "Where recordings and the trace go. Left out, recordings/ beside config.yaml."),
            key("min_duration_seconds", .number,
                "Clips shorter than this are discarded.", default: 0.3),
            key("speech_gate", .bool, "Skip clips with no speech in them.", default: true),
            key("second_opinion", .bool,
                "Decode each clip again with silence padding, and keep the longer decode."
                    + " Needs speech_gate.",
                default: true),
            key("microphones", .list(.text),
                "Which microphone to record through, best first. Empty means the"
                    + " system's input device.",
                default: [String]()),
        ])
    }

    static var feedback: Section {
        Section(source: "Config.Feedback",
                keys: Config.Feedback.CodingKeys.allCases.map(\.stringValue), fields: [
            key("sound", .bool, "Play a short sound on start and stop.", default: true),
            key("sound_volume", .number,
                "How loud those sounds are, from 0 to 1. Clamped to that range.",
                default: 0.3),
            key("overlay", .bool, "Show the pill while the microphone is open.", default: true),
            key("correct_offer", .bool,
                "After a dictation, offer to correct it for a few seconds.", default: true),
            key("confidence", .bool,
                "Colour each word on the offer by how sure the decoder was. Needs"
                    + " correct_offer.",
                default: false),
            key("theme", .choice(ContextAppearance.allCases.map(\.rawValue)),
                "Appearance of the floating surfaces. system follows macOS.",
                default: ContextAppearance.system.rawValue),
            key("primary_color", .pattern("^#[0-9A-Fa-f]{6}$"),
                "The primary colour, as #RRGGBB.", default: ContextIdentity.defaultPrimary),
            key("low_confidence", .object(lowConfidence),
                "When the offer warns that the words may not be yours."),
        ])
    }

    static var lowConfidence: Section {
        Section(source: "Config.Feedback.LowConfidence",
                keys: Config.Feedback.LowConfidence.CodingKeys.allCases.map(\.stringValue),
                fields: [
            key("sentence", .number,
                "Warn when asr.confidence is below this. 0 turns the warning off.",
                default: 0.80),
            key("word", .number,
                "And a word is below this. 0 turns the warning off.", default: 0.50),
            key("hold_return", .number,
                "Seconds a bare Return is held back after a warned dictation. 0 lets"
                    + " every Return through.",
                default: 1.5),
        ])
    }

    static var transcription: Section {
        let phrases = Kind.either([.text, .list(.text)])
        let keys = Config.Transcription.CodingKeys.allCases.map(\.stringValue)
            + Config.Transcription.legacyKeys
        return Section(source: "Config.Transcription", keys: keys, fields: [
            key("enabled", .bool, "Transcribe at all.", default: true),
            key("insert_mode", .choice(["paste", "clipboard"]),
                "paste types into the app you are in and needs Accessibility. clipboard"
                    + " copies, and you press ⌘V.",
                default: "paste"),
            key("activation_phrases", phrases,
                "Say one of these first and what follows is an instruction. Empty turns"
                    + " spoken commands off.",
                default: ["hey parrot"]),
            key("rewrite_line", .bool,
                "In a terminal, clear the input line and retype it to apply a correction.",
                default: true),
            key("languages", .list(.choice(DictationLanguage.supported)),
                "Languages you dictate in, most spoken first. One entry turns off"
                    + " language detection.",
                default: ["en"]),
            key("sentence_repair", .object(sentenceRepair),
                "Takes out the marks a pause put mid-sentence. Runs first, always."),
            key("vocabulary", .object(vocabulary),
                "Matches vocabulary.yaml terms and settles each against its sentence."
                    + " Runs second, always."),
            key("context_spelling", .object(contextSpelling),
                "Spells a dictated word the way the screen writes it. Runs last."),
            key("pipeline", .list(step),
                "What a transcript runs through, in order. Left out, every stage runs."),
            key("activation_phrase", phrases, "The older name for activation_phrases.",
                deprecated: "the older name for `activation_phrases:`. Still read"),
            key("correction_phrase", phrases, "The oldest name for activation_phrases.",
                deprecated: "the oldest name for `activation_phrases:`. Still read"),
            key("replacements", .open(.anything), "Retired.",
                deprecated: "no longer does anything — " + Config.retiredReplacementsAdvice),
            key("numbers", .bool, "Retired.",
                deprecated: "no longer does anything — "
                    + (Config.retiredStageAdvice("numbers") ?? "it is a pipeline stage now")),
            key("fuzzy_matching", .bool, "Retired.",
                deprecated: "no longer does anything — it is a pipeline stage now"),
            key("pipelines", .anything, "Retired. Nothing under it is read.",
                deprecated: "is retired and nothing under it is read. Write one `pipeline:`"
                    + " list, with `when: language == \"fr\"` on a step that belongs to"
                    + " one language"),
            key("interpret", .object(sentenceRepair), "The older name for sentence_repair.",
                deprecated: "`interpret:` is called `sentence_repair:` now — same keys,"
                    + " still read under the old name"),
        ])
    }

    static var sentenceRepair: Section {
        Section(source: "Config.Transcription.SentenceRepair",
                keys: Config.Transcription.SentenceRepair.CodingKeys.allCases
                    .map(\.stringValue),
                fields: [
            key("enabled", .bool, "false is the only way off.", default: true),
            key("marks", .marks,
                "What a boundary may be written with, one punctuation character each,"
                    + " at least one of . ? !. Left out, the set for the language."),
            key("capitals", .bool,
                "Read a capital with no mark in front of it as a boundary too.",
                default: true),
            key("pause", .number,
                "Seconds of silence a bare capital needs first. 0 reads every one."),
        ])
    }

    static var contextSpelling: Section {
        Section(source: "Config.Transcription.ContextSpelling",
                keys: Config.Transcription.ContextSpelling.CodingKeys.allCases
                    .map(\.stringValue),
                fields: [
            key("enabled", .bool, "Reads the screen and the field at every press.",
                default: true),
        ])
    }

    static var vocabulary: Section {
        Section(source: "Config.Transcription.Vocabulary",
                keys: Config.Transcription.Vocabulary.CodingKeys.allCases.map(\.stringValue),
                fields: [
            key("enabled", .bool, "false is the only way off.", default: true),
            key("sound_below", .range(Bounds(min: 0, max: 1)),
                "How close a run of words must sound to a term, from 0 to 1. Left out,"
                    + " the value in vocabulary.yaml, else 0.85."),
            key("gate_sentence", .bool,
                "Read the sentence before keeping a match. Left out, the value in"
                    + " vocabulary.yaml, else true."),
            key("asks", .bool,
                "Ask before typing a name it could not settle. Left out, the value in"
                    + " vocabulary.yaml, else true."),
            key("slot_floor", slotFloor,
                "How far the heard word must win by before a rewrite is refused."
                    + " Built in: 0.20 in English, 0.30 in French."),
            key("near_misses", .bool, "Bench switch: also match a rendering one edit away.",
                default: true),
            key("by_sound", .bool, "Bench switch: also match words that sound like a term.",
                default: true),
            key("gate", .bool, "Bench switch: the word lists and the slot's part of speech.",
                default: true),
            key("slot_gate", .bool, "Bench switch: the slot model. false downloads nothing.",
                default: true),
            key("portrait", .bool,
                "Bench switch: a term's own sentences and its counter-examples.",
                default: true),
            key("lowercase_refused", .bool,
                "Bench switch: refuse a term written where the decoder wrote lower case.",
                default: true),
            key("caps", .object(caps),
                "Bench only. Both perSlot and perTerm are required here. On a pipeline"
                    + " step they are max_per_slot and max_per_term."),
        ])
    }

    static var caps: Section {
        Section(source: "VocabularyPass.Caps",
                keys: VocabularyPass.Caps.CodingKeys.allCases.map(\.stringValue), fields: [
            key("perSlot", perSlot, "Readings per place, the heard word included. At most 2.",
                default: 2, required: true),
            key("perTerm", perTerm, "Places in one sentence that may be about one term.",
                default: 2, required: true),
            key("readings", .integer, "Retired.",
                deprecated: "nothing reads it. It capped a lettered menu, and there is no"
                    + " menu. Delete the line"),
            key("slots", .integer, "Retired.",
                deprecated: "nothing reads it. It capped one model call, and this stage"
                    + " makes none. Delete the line"),
        ])
    }

    /// `Caps.problems` refuses anything below 1, and a third reading per place.
    static var perSlot: Kind {
        .wholeRange(Bounds(min: 1, max: Double(VocabularyPass.Caps.readingCeiling)))
    }
    static var perTerm: Kind { .wholeRange(Bounds(min: 1)) }

    /// A number for every language, or one per language.
    static var slotFloor: Kind {
        let floor = Kind.range(Bounds(min: 0, max: 2, aboveMin: true))
        return .either([floor, .object(Section(
            source: "DictationLanguage.supported", keys: DictationLanguage.supported,
            fields: DictationLanguage.supported.map {
                key($0, floor, "The floor when the transcript is in this language.")
            }
        ))])
    }

    /// A bare stage name, or a mapping that names a stage or a transform.
    static var step: Kind {
        let stages = Kind.choice(Pipeline.stageNames + ["interpret"])
        let entry = Config.Transcription.PipelineEntry.self
        return .either([stages, .object(Section(
            source: "Config.Transcription.PipelineEntry", keys: entry.schemaKeys, fields: [
                key("stage", stages, "A built-in stage."),
                key("transform", .text, "A transform from transforms:, by name."),
                key("when", .text,
                    "Run only when this holds: /a regex/ on the text, or an expression"
                        + " like language == \"fr\"."),
                key("unless", .text, "Skip when this holds. Same forms as when."),
                key("app", .text,
                    "Run only in apps this regex matches, on name and bundle id."),
                key("marks", .marks, "sentence_repair: what a boundary may be written with."),
                key("capitals", .bool, "sentence_repair: read a bare capital as a boundary."),
                key("pause", .number, "sentence_repair: silence a bare capital needs first."),
                key("near_misses", .bool, "vocabulary: also match a rendering one edit away."),
                key("by_sound", .bool, "vocabulary: also match words that sound like a term."),
                key("gate", .bool, "vocabulary: the word lists and the slot's part of speech."),
                key("slot_gate", .bool, "vocabulary: the slot model."),
                key("portrait", .bool, "vocabulary: a term's own sentences."),
                key("lowercase_refused", .bool,
                    "vocabulary: refuse a term where the decoder wrote lower case."),
                key("slot_floor", slotFloor, "vocabulary: the slot floor, as in the block."),
                key("max_per_slot", perSlot, "vocabulary: readings per place. At most 2.",
                    default: 2),
                key("max_per_term", perTerm,
                    "vocabulary: places in one sentence about one term.", default: 2),
                key("prompt", .text, "The older spelling of transform.",
                    deprecated: "the older spelling of `transform:`. Still read"),
                key("vocabulary", .text, "Retired: named a prompt file for the vocabulary stage.",
                    deprecated: "names a prompt file. The prompt is part of the app now."
                        + " Delete the line: the pass is `transcription.vocabulary:` and"
                        + " runs either way"),
                key("review", .anything, "Retired.",
                    deprecated: "named the model that kept or reverted each substitution."
                        + " There is no model in that stage now. The key is read and does"
                        + " nothing"),
                key("max_slots", .integer, "Retired.",
                    deprecated: "nothing reads it. It capped one model call, and this stage"
                        + " makes none. Delete the line"),
                key("max_readings", .integer, "Retired.",
                    deprecated: "nothing reads it. It capped a lettered menu, and there is"
                        + " no menu. Delete the line"),
            ]
        ))])
    }

    static var commands: Section {
        Section(source: "Config.Commands",
                keys: Config.Commands.CodingKeys.allCases.map(\.stringValue), fields: [
            key("router", .text,
                "The model that matches what you said to a capability. Left out, the"
                    + " default model."),
            key("spelling", .text,
                "The model that reads a rule out of a spelled word. Left out, the default"
                    + " model."),
            key("catch_all", .either([.bool, .text, .object(modelRef)]),
                "An instruction no capability covers: a model name, a model with settings,"
                    + " or false to refuse them.",
                default: true),
        ])
    }

    static var model: Section {
        Section(source: "ModelSpec", keys: ModelSpec.CodingKeys.allCases.map(\.stringValue),
                fields: [
            key("api", .choice(ModelSpec.API.allCases.map(\.rawValue)),
                "The protocol, not the vendor.", default: ModelSpec.API.ollama.rawValue),
            key("model", .text, "The model id, as the provider spells it.", required: true),
            key("endpoint", .text, "Where to send it. Left out, the default for the protocol."),
            key("api_key", .text,
                "keychain, env:NAME, file:PATH, or the key itself. Left out, the keychain"
                    + " for a model that is not ollama."),
            key("reasoning", .choice(ModelSpec.Reasoning.allCases.map(\.rawValue)),
                "How hard the model may think.", default: ModelSpec.Reasoning.off.rawValue),
            key("temperature", .number, "Sent only when written. Reasoning models reject it."),
            key("max_tokens", .integer, "Replaces the budget the caller worked out."),
            key("timeout_seconds", .number,
                "How long before the transcript is let through untouched.", default: 20),
            key("keep_loaded", .bool, "Ollama only: pin the model in memory.", default: true),
            key("default", .bool,
                "The model that runs whatever names no model. Exactly one, when there are"
                    + " several.",
                default: false),
            key("params", .open(.anything),
                "Merged into the request body last, unchecked. null removes a field."),
        ])
    }

    static var modelRef: Section {
        let connection = "describes a connection — put it in `models:` and name it with `use:`"
        return Section(source: "ModelRef", keys: ModelRef.CodingKeys.allCases.map(\.stringValue),
                       fields: [
            key("use", .text, "A name from models:. Left out, the default model."),
            key("reasoning", .choice(ModelSpec.Reasoning.allCases.map(\.rawValue)),
                "Overrides the model's reasoning here."),
            key("temperature", .number, "Overrides the model's temperature here."),
            key("max_tokens", .integer, "Overrides the model's max_tokens here."),
            key("timeout_seconds", .number, "Overrides the model's timeout here."),
            key("params", .open(.anything), "Merged over the model's params here."),
            key("api", .text, "Not allowed here.", deprecated: connection),
            key("endpoint", .text, "Not allowed here.", deprecated: connection),
            key("model", .text, "Not allowed here.", deprecated: connection),
            key("api_key", .text, "Not allowed here.", deprecated: connection),
        ])
    }

    static var transform: Section {
        let file = Kind.object(Section(
            source: "Config.TransformEntry.BodyFile", keys: Config.bodyFileKeys, fields: [
                key("path", .text, "A file in transforms/<name>/, or a path under transforms/."),
            ]
        ))
        return Section(source: "Config.TransformEntry", keys: Config.transformKeys, fields: [
            key("name", .text, "The id a pipeline step or a when: names."),
            key("description", .text,
                "What you would say to ask for it. The router matches against this."),
            key("display", .text, "Shown on the menu bar while it runs."),
            key("prompt", .either([.text, file]),
                "Asks a model. Inline text, or { path: file.md }."),
            key("replace", .either([file, .open(.list(.text))]),
                "A substitution table, wanted: [heard, heard], or { path: file.yaml }."),
            key("command", .text,
                "A program: the transcript on stdin, the rewrite on stdout."),
            key("returns", .choice(["json", "text"]),
                "json makes a command speak the structured protocol.", default: "text"),
            key("model", .either([.text, .object(modelRef)]),
                "Which model a prompt runs on: a name from models:, or { use: name, … }."),
            key("timeout_seconds", .number,
                "How long a command may take before the text is let through untouched.",
                default: CommandRunner.timeout),
            key("confirm", .bool, "Show the result and wait before replacing a selection.",
                default: true),
            key("tests", .either([.text, file]),
                "The case set --eval scores by default. Left out, cases.yaml."),
            key("offer", .bool, "Put a chip for this on the pill after a dictation.",
                default: false),
            key("key", .text, "The one letter on that chip."),
            key("say", .either([.text, .list(.text)]),
                "What to call it out loud, besides its name."),
            key("done", .text, "What the pill says when this leaves the text alone on purpose."),
            key("failed", .text, "What the pill says when this could not run. Markdown."),
            key("content", .either([.text, file]), "The older name for prompt.",
                deprecated: "the older name for `prompt:`. Still read"),
        ])
    }

    static var updates: Section {
        Section(source: "Config.UpdatePolicy",
                keys: Config.UpdatePolicy.CodingKeys.allCases.map(\.stringValue), fields: [
            key("after_days", .integer,
                "Days a release must exist before it is offered. 0 offers it at once."
                    + " Negative never checks.",
                default: 0),
        ])
    }

    static var logging: Section {
        Section(source: "Config.Logging",
                keys: Config.Logging.CodingKeys.allCases.map(\.stringValue), fields: [
            key("text", .bool, "The log at ~/Library/Logs/ParrotFlow.log.", default: true),
            key("audio", .bool, "Keep each dictation's recording on disk.", default: false),
            key("spans", .bool,
                "One timeline per dictation in spans.jsonl, rotating at 64 MB.",
                default: true),
        ])
    }

    static var llm: Section {
        let retired = "part of the retired `llm:` block"
        return Section(source: "Config.LLM",
                       keys: Config.LLM.CodingKeys.allCases.map(\.stringValue),
                       fields: ["enabled", "model", "endpoint", "router", "vocabulary", "default",
                                "timeout_seconds", "keep_loaded"].map {
            key($0, .anything, "Retired.", deprecated: retired)
        })
    }

    // MARK: - Drift

    /// Every key the parser reads with no entry here, and every entry the
    /// parser does not read. Empty means the table is complete.
    static func drift() -> [String] {
        var found: Set<String> = []
        var seen: Set<String> = []
        func visit(_ kind: Kind) {
            switch kind {
            case .object(let section):
                guard seen.insert(section.source).inserted else { return }
                check(section)
                section.fields.forEach { visit($0.kind) }
            case .list(let inner), .open(let inner):
                visit(inner)
            case .either(let kinds):
                kinds.forEach(visit)
            default:
                break
            }
        }
        func check(_ section: Section) {
            let written = section.fields.map(\.name)
            for name in Set(written) where written.filter({ $0 == name }).count > 1 {
                found.insert("\(section.source): \"\(name)\" has two schema entries")
            }
            for name in section.keys where !written.contains(name) {
                found.insert("\(section.source): the parser reads \"\(name)\","
                    + " and the schema has no entry for it")
            }
            for name in written where !section.keys.contains(name) {
                found.insert("\(section.source): the schema has \"\(name)\","
                    + " and the parser does not read it")
            }
        }
        visit(.object(root))
        return found.sorted()
    }

    // MARK: - JSON Schema

    static func jsonSchema() -> [String: Any] {
        var out = json(.object(root))
        out["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        out["title"] = "ParrotFlow config.yaml"
        out["description"] = "Written by `ParrotFlow --schema`. `--check-config` is the"
            + " final word on what the app reads."
        return out
    }

    static func rendered() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: jsonSchema(),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func json(_ kind: Kind) -> [String: Any] {
        switch kind {
        case .bool: return ["type": "boolean"]
        case .integer: return ["type": "integer"]
        case .number: return ["type": "number"]
        case .range(let bounds): return bounded("number", bounds)
        case .wholeRange(let bounds): return bounded("integer", bounds)
        case .text: return ["type": "string"]
        case .pattern(let pattern): return ["type": "string", "pattern": pattern]
        case .choice(let values):
            // The enum is what an editor offers; the pattern accepts any casing.
            return ["type": "string", "anyOf": [["enum": values], ["pattern": anyCase(values)]]]
        case .marks:
            return [
                "type": "array", "minItems": 1,
                "items": ["type": "string", "minLength": 1, "maxLength": 1],
                "contains": ["enum": SentenceReadings.enders.sorted()],
            ]
        case .list(let inner): return ["type": "array", "items": json(inner)]
        case .object(let section):
            var properties: [String: Any] = [:]
            for field in section.fields { properties[field.name] = json(field) }
            var out: [String: Any] = [
                "type": "object", "properties": properties, "additionalProperties": false,
            ]
            let required = section.fields.filter(\.required).map(\.name)
            if !required.isEmpty { out["required"] = required }
            return out
        case .open(let inner): return ["type": "object", "additionalProperties": json(inner)]
        case .anything: return [:]
        case .either(let kinds): return ["anyOf": kinds.map(json)]
        }
    }

    private static func json(_ field: Field) -> [String: Any] {
        var out = json(field.kind)
        var said = field.help
        if let deprecated = field.deprecated {
            out["deprecated"] = true
            said += " " + deprecated.prefix(1).uppercased() + deprecated.dropFirst()
            if !said.hasSuffix(".") { said += "." }
        }
        out["description"] = said
        if let fallback = field.fallback { out["default"] = decimal(fallback) }
        // A section with every line commented out is null, and reads as absent.
        if let type = out["type"] as? String, type == "object" || type == "array" {
            out["type"] = [type, "null"]
        }
        return out
    }

    private static func bounded(_ type: String, _ bounds: Bounds) -> [String: Any] {
        var out: [String: Any] = ["type": type]
        if let min = bounds.min { out[bounds.aboveMin ? "exclusiveMinimum" : "minimum"] = min }
        if let max = bounds.max { out["maximum"] = max }
        return out
    }

    /// `^(?:[oO][fF][fF]|…)$`. JSON Schema patterns have no case-insensitive flag.
    private static func anyCase(_ values: [String]) -> String {
        let spelled = values.map { value in
            NSRegularExpression.escapedPattern(for: value).map { letter -> String in
                let lower = letter.lowercased(), upper = letter.uppercased()
                return lower == upper ? String(letter) : "[\(lower)\(upper)]"
            }.joined()
        }
        return "^(?:\(spelled.joined(separator: "|")))$"
    }

    /// JSONSerialization writes 0.3 as 0.29999999999999999. Swift's own
    /// description is the shortest form that reads back the same.
    private static func decimal(_ value: Any) -> Any {
        guard let number = value as? Double else { return value }
        return NSDecimalNumber(string: "\(number)")
    }

    // MARK: - Unknown keys

    /// A key in the file that no setting reads.
    struct Unknown: Equatable {
        let path: String
        let suggestion: String?

        var said: String {
            "\(path): not a setting." + (suggestion.map { " Did you mean \"\($0)\"?" } ?? "")
        }
    }

    /// Every key in `text` the schema does not know, by full path.
    ///
    /// The decoder never sees a key its `CodingKeys` does not list, so this
    /// reads the same YAML again as a plain tree. A deprecated key is known,
    /// so it gets no line here, but what is under it is still checked.
    static func unknownKeys(in text: String) -> [Unknown] {
        guard let node = try? Yams.compose(yaml: text) else { return [] }
        var found: [Unknown] = []
        walk(node, .object(root), at: "", into: &found)
        return found
    }

    private static func walk(_ node: Node, _ kind: Kind, at path: String, into found: inout [Unknown]) {
        func joined(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
        switch kind {
        case .object(let section):
            guard let mapping = node.mapping else { return }
            for (keyNode, value) in mapping {
                guard let key = keyNode.scalar?.string else { continue }
                guard let field = section.field(key) else {
                    let current = section.fields.filter { $0.deprecated == nil }.map(\.name)
                    found.append(Unknown(path: joined(key), suggestion: closest(to: key, in: current)))
                    continue
                }
                walk(value, field.kind, at: joined(key), into: &found)
            }
        case .open(let inner):
            guard let mapping = node.mapping else { return }
            for (keyNode, value) in mapping {
                walk(value, inner, at: joined(keyNode.scalar?.string ?? "?"), into: &found)
            }
        case .list(let inner):
            guard let sequence = node.sequence else { return }
            for (index, item) in sequence.enumerated() {
                let name = item.mapping?["name"]?.scalar?.string
                walk(item, inner, at: "\(path)[\(name ?? String(index))]", into: &found)
            }
        case .either(let kinds):
            if let mapping = node.mapping {
                // The parser reads `{ path: <string> }` as a file before it reads a
                // table, and ignores whatever else is beside `path`.
                let file = kinds.first { $0.section?.field("path") != nil }
                if let file, mapping["path"]?.scalar != nil {
                    walk(node, file, at: path, into: &found)
                    return
                }
                // An open branch accepts any key, so there is nothing to report.
                guard !kinds.contains(where: \.isOpen),
                      let object = kinds.first(where: { $0.section != nil }) else { return }
                walk(node, object, at: path, into: &found)
            } else if node.sequence != nil, let list = kinds.first(where: \.isList) {
                walk(node, list, at: path, into: &found)
            }
        default:
            return
        }
    }

    /// The nearest name, when it is close enough to be the one meant.
    static func closest(to key: String, in names: [String]) -> String? {
        let limit = max(1, min(2, key.count / 3))
        return names
            .map { (name: $0, distance: editDistance(key.lowercased(), $0.lowercased())) }
            .filter { $0.distance <= limit }
            .min { $0.distance < $1.distance }?
            .name
    }

    /// Edits between two names, where swapping two neighbours is one edit:
    /// `moed` is one from `mode`.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1,
                                  table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}

private extension ConfigSchema.Kind {
    var isOpen: Bool {
        switch self {
        case .open, .anything: return true
        default: return false
        }
    }

    var section: ConfigSchema.Section? {
        if case .object(let section) = self { return section }
        return nil
    }

    var isList: Bool {
        if case .list = self { return true }
        return false
    }
}
