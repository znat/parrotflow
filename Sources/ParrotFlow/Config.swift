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
    /// Whether there is a model to call at all.
    ///
    /// `llm.enabled` used to say this, from a time when the model was implicit
    /// and there was no other way to mean "I have none". A config that defines
    /// no model says the same thing and cannot fall out of step with itself.
    var llmEnabled: Bool { !models.isEmpty }
    /// Every model this config can reach, by the name it was given.
    ///
    /// A name is all a transform ever mentions — never a vendor, never an
    /// endpoint. Empty means the one implied by `llm:`, which is what every
    /// config written before this said and still says.
    var models: [String: ModelSpec] = [:]
    var commands = Commands()
    /// Top-level keys that were read purely so they can be refused, with the
    /// line that replaces them. See `problems`.
    var retiredKeys: [String] = []
    var updates: UpdatePolicy = UpdatePolicy()
    var logging: Logging = Logging()
    /// Everything nameable: `transforms:`, plus anything still written under
    /// the older `prompts:`.
    var transforms: [Transform] = []
    /// The entries dropped because a `path:` named a file that could not be
    /// read — see `assembled`. Reported by `problems()`, because a transform
    /// that is not there is not the same as one that does nothing.
    var unreadableTransforms: [String] = []

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
    /// Whether an instruction no capability covers is attempted or refused.
    ///
    /// A view over `commands.catch_all`, kept because a dozen call sites ask
    /// this question and none of them care where the answer is written.
    var freeForm: Bool { commands.catchAllEnabled }

    /// Read from `vocabulary.yaml` beside the config, not from `config.yaml`.
    /// It is maintained by the app rather than by hand — see `Vocabulary`.
    var vocabulary: Vocabulary = Vocabulary()

    /// Named word lists, written once and referred to by name.
    ///
    /// The same list — "the determiners, so this is prose and not a name" —
    /// was pasted into nine regexes across two config files and one Python set,
    /// and the copies had already drifted: one said `the|a|an`, another held
    /// forty French words. A `replace:` pattern now writes `{{determiners}}`
    /// and a transform script reads the same list out of the scope, so there
    /// is one definition and adding a language is adding words to it.
    ///
    /// Deliberately not per language. `dotted` has always merged English and
    /// French into one alternation and it measures clean, because the words do
    /// not collide.
    var lists: [String: [String]] = [:]

    enum CodingKeys: String, CodingKey {
        case hotkey, audio, feedback, transcription, llm, models, commands
        case transforms, prompts, updates, logging
        case freeForm = "free_form"
        case lists
    }

    private static let listReference = try? NSRegularExpression(pattern: #"\{\{(\w+)\}\}"#)

    /// Every `{{name}}` a pattern refers to, in the order written.
    static func listNames(in pattern: String) -> [String] {
        guard pattern.contains("{{"), let expression = listReference else { return [] }
        return expression
            .matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern))
            .compactMap { Range($0.range(at: 1), in: pattern).map { String(pattern[$0]) } }
    }

    /// `{{name}}` replaced by the list, as a regex alternation.
    ///
    /// Longest first, so `semi colon` cannot be eaten by `colon` sitting
    /// earlier in the same alternation.
    ///
    /// Nil when a name is unknown or names an empty list. The rule is then
    /// skipped, the way one with an invalid pattern is.
    ///
    /// Skipped rather than expanded to something, because no expansion is safe
    /// both ways. Emptied, `(?:)` matches everywhere: a positive rule fires on
    /// every word. Left literal it matches nothing, so
    /// `(?!(?:{{determiners}})\b)` always succeeds and `dotted` rewrites prose.
    /// A guard and a plain match want opposite fallbacks, so not running is the
    /// only answer that is right for both. `replacementProblems` refuses the
    /// config first; this is what happens if one is loaded anyway.
    func expanded(_ pattern: String) -> String? {
        guard pattern.contains("{{") else { return pattern }
        var out = pattern
        for name in Config.listNames(in: pattern) {
            guard let words = lists[name], !words.isEmpty else { return nil }
            let alternation = words
                .sorted { $0.count > $1.count }
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            out = out.replacingOccurrences(of: "{{\(name)}}", with: alternation)
        }
        return out
    }

    /// The lists as scope values, for a transform that is a program rather than
    /// a table. Joined on `; ` because a `Scope.Value` is a scalar.
    var listVariables: [String: Scope.Value] {
        lists.reduce(into: [:]) { out, entry in
            out[entry.key] = .string(entry.value.joined(separator: "; "))
        }
    }

    /// The words you dictate that the recogniser gets wrong, and what the app
    /// has learnt about each one.
    ///
    /// Not only names. A colleague's surname, a drug brand, an internal
    /// project, a library, an acronym, or any word a non-native speaker says in
    /// a way the model was not trained on — the common property is that it
    /// sounds like something else, not that it is a proper noun.
    ///
    /// Its own file because the two halves have different owners. `config.yaml`
    /// is written by a person and read by the app; `vocabulary.yaml` is written
    /// by the app — the correction panel, `--learn`, the calibrate skill — and
    /// only read by a person. Mixing them means a hand edit and a learnt entry
    /// land in the same file, and one of them eventually loses.
    struct Vocabulary: Decodable, Equatable {

        /// Read and ignored.
        ///
        /// It used to turn on a search of the audio itself — a CTC keyword
        /// spotter and a rescorer, on a ~98 MB model. That pass is gone: it
        /// never worked well enough to switch on, and everything it was meant
        /// to do is now done on the text, by sound, with no audio at all.
        ///
        /// Kept because it is written in files nobody edits by hand, and a
        /// vocabulary that stops loading over a retired key is a vocabulary
        /// that stops working. `notices()` names it once.
        var acoustic: Bool = false

        /// How far a decoded word's spelling may sit from a term and still be
        /// worth a line on the judge's menu. FluidAudio's similarity, where
        /// 1.0 is the term written out exactly.
        ///
        /// One of the two numbers that replaced the single floor (F1). That
        /// floor decided both what to look at and what to write, and no value
        /// did both jobs: at 0.75 only 2 of 20 misheard names were caught, and
        /// low enough to catch them "in general" became "in Redcrawl". This
        /// one only decides what to look at. Being offered costs a menu line;
        /// being missed cannot be recovered downstream at any price.
        ///
        /// Shipped untuned. F5's sentences suggest 0.50 is still permissive
        /// even for a proposal, and measuring that is PR 7's job.
        var offerBelow: Float = 0.50

        /// How far the audio may argue against a proposal, in nats of raw CTC
        /// score, before the proposal is dropped instead of offered.
        ///
        /// Read and ignored, with `acoustic:`. It was a margin in nats against
        /// the audio, and there is no audio to weigh a reading against any
        /// more.
        ///
        /// Generous. `versal` -> `Vercel` is 0.82 against and correct, so the
        /// gate has to sit well clear of an ordinary near-tie. Also shipped
        /// untuned.
        var decideAbove: Float = 3.0

        /// How close a run of words must *sound* to a term before it is worth
        /// a line on the judge's menu.
        ///
        /// The sound twin of `offerBelow`, on the same metric, and a much
        /// tighter number because it buys much more. Measured over 20891 real
        /// dictations — see `VocabularyJudge.phonemeParts` for the table.
        /// 0.85 fires 147 times in that whole archive, 33 of them a name this
        /// speaker lost; 0.80 fires 826 times and most of the extra is
        /// `and me` reaching `Andrey`.
        var soundBelow: Float = 0.85


        /// One way this speaker's mouth turns a term into something else, and
        /// what is known about that.
        ///
        /// A rendering used to be a bare string in a `heard:` list, which said
        /// only that somebody once saw it. That is not enough to decide
        /// anything with. A rendering seen once and never again is noise; one
        /// seen nine times is how this person says the word. `seen` makes that
        /// difference decidable, and `from` says who put it there, so an entry
        /// mined from the archive can be told from one a person confirmed by
        /// correcting a transcript.
        ///
        /// Nothing mechanical reads `seen` or `from` yet. They are recorded
        /// here so PR 8 has something to cap and prune on; a count that starts
        /// being kept the day it is first used starts at zero for every entry
        /// that already existed.
        struct Pronunciation: Decodable, Equatable {
            /// Where an entry came from. `legacy` is not a source, it is the
            /// absence of one: a bare `heard:` list, or a `pronunciations:`
            /// entry written without `from:`, records nothing about its own
            /// provenance and says so rather than guessing.
            enum Source: String, Decodable, Equatable {
                case correction
                case mined
                case calibration
                case legacy
            }

            /// The spelling the decoder produced where the term was said.
            var heard: String
            /// How that rendering sounds, as IPA. Optional: when it is absent
            /// the sound is worked out from `heard` at load, and the entry
            /// behaves the same.
            ///
            /// Written down, a rendering stops being one spelling and becomes
            /// a class of sounds. `Silverstein` as a string reaches only
            /// `Silverstein`; as /sɪlvɚstaɪn/ it also reaches `Silberstein`,
            /// which the decoder writes and nobody wrote down. That is the
            /// only reason this field exists — see
            /// `VocabularyJudge.phonemeParts`.
            ///
            /// Write it when the spelling misleads: espeak reads `Preci` as
            /// /pɹɛsaɪ/, "pre-sigh", and no floor rescues that.
            var phonemes: String?
            /// How many times it has been seen. Zero means never counted,
            /// which is every entry written before this key existed.
            var seen: Int = 0
            var from: Source = .legacy
            /// A free line for a person: why this entry is here, or what it
            /// costs. Never parsed.
            var note: String?
            /// What `from:` said, when it said something this does not know.
            /// Kept rather than dropped so `notices()` can name it — a label
            /// nobody can read is worth one line, once, rather than silence.
            var unreadableFrom: String?

            init(
                heard: String, phonemes: String? = nil, seen: Int = 0,
                from: Source = .legacy,
                note: String? = nil, unreadableFrom: String? = nil
            ) {
                self.heard = heard
                self.phonemes = phonemes
                self.seen = seen
                self.from = from
                self.note = note
                self.unreadableFrom = unreadableFrom
            }

            enum CodingKeys: String, CodingKey { case heard, phonemes, seen, from, note }

            /// Two shapes. The mapping is what the app writes; the bare string
            /// is what a person types when they have nothing else to say:
            ///
            ///     - heard: Versailles
            ///       phonemes: vɚsaɪ
            ///       seen: 3
            ///       from: mined
            ///     - Versal
            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let word = try? single.decode(String.self) {
                    self.init(heard: word)
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let word = try c.decode(String.self, forKey: .heard)
                // An unreadable `from:` is read as `legacy` rather than
                // refused. It is a label on a rendering, and losing the
                // rendering over a typo in its label would cost the thing that
                // works to protect the thing that does not do anything yet.
                let source = (try? c.decodeIfPresent(String.self, forKey: .from))
                    .flatMap { $0 }
                let read = source.flatMap(Source.init(rawValue:))
                self.init(
                    heard: word,
                    phonemes: try c.decodeIfPresent(String.self, forKey: .phonemes),
                    seen: (try? c.decodeIfPresent(Int.self, forKey: .seen)).flatMap { $0 } ?? 0,
                    from: read ?? .legacy,
                    note: try c.decodeIfPresent(String.self, forKey: .note),
                    unreadableFrom: read == nil ? source : nil
                )
            }
        }

        /// One term, and what is known about it.
        ///
        /// `floor: off` means never match by sound at all — the honest setting
        /// when the decoder writes the term and an ordinary word identically.
        /// Measured here: "Claude" and "cloud" both come back as "cloud", so
        /// no threshold can separate them. That is a switch, not a threshold,
        /// so the two file-level numbers do not replace it.
        ///
        /// A *number* under `floor:` is legacy. It is still honoured, as this
        /// term's `offer_below`, and `--check-config` says so.
        ///
        /// `pronunciations` is for renderings no number can reach. "Prezi" is
        /// 0.33 from "Praisy" and would need a floor that swallowed every
        /// "praise". As an exact rule it costs nothing and cannot misfire, and
        /// `Vocabulary.prepare` also hands its sound to the CTC spotter.
        struct Term: Decodable, Equatable {
            /// A legacy per-term `floor:` number, read as this term's
            /// `offer_below`. Nil means the file-level one applies.
            var offerBelow: Float?
            /// `floor: off` — never matched by sound at all, by its own
            /// spelling or through its pronunciations. Its renderings are
            /// exact rules and nothing else, because a rendering is registered
            /// under the term's name and a term with `floor: off` has no entry
            /// for the spotter to report. That is the intended reading:
            /// "Claude" and "cloud" come back identical because they *sound*
            /// identical, so the audio separates them no better than the
            /// spelling does.
            var never = false
            var pronunciations: [Pronunciation] = []
            /// What kind of thing the term names, written by the correction
            /// panel. Nil means nobody said, which is every term written before
            /// the key existed. Nothing mechanical reads it yet — see
            /// `WordKind`.
            var kind: WordKind?
            /// What `kind:` said, when it said something this does not know.
            /// Kept rather than dropped so `notices()` can name it.
            var unreadableKind: String?
            /// True when the list arrived under the old `heard:` key, so
            /// `notices()` can name the key and say what to write instead.
            var wroteHeard = false

            /// Just the renderings, for the callers that only want the
            /// spellings — the exact rules, and the "can anything reach this
            /// term at all" check in `notices()`.
            var heard: [String] { pronunciations.map(\.heard) }

            init(
                offerBelow: Float? = nil, never: Bool = false,
                pronunciations: [Pronunciation] = [], kind: WordKind? = nil,
                unreadableKind: String? = nil, wroteHeard: Bool = false
            ) {
                self.offerBelow = offerBelow
                self.never = never
                self.pronunciations = pronunciations
                self.kind = kind
                self.unreadableKind = unreadableKind
                self.wroteHeard = wroteHeard
            }

            enum CodingKeys: String, CodingKey { case floor, heard, pronunciations, kind }

            /// Five shapes, because most terms need none of this:
            ///
            ///     Tasmeen:                              nothing to say
            ///     Mirza: 0.85                           a legacy floor
            ///     Praisy: [Prissy, Pressy]              renderings, legacy
            ///     Claude: {floor: off, heard: [cloud]}  renderings, legacy
            ///     Vercel: {pronunciations: [...]}       renderings, with counts
            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer() {
                    if single.decodeNil() { self.init(); return }
                    if let number = try? single.decode(Float.self) {
                        self.init(offerBelow: number); return
                    }
                    if let listed = try? single.decode([String].self) {
                        self.init(
                            pronunciations: listed.map { Pronunciation(heard: $0) },
                            wroteHeard: true
                        )
                        return
                    }
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // An unreadable `kind:` is dropped rather than refused, for the
                // same reason `from:` is on a pronunciation: it is a label, and
                // nothing reads it yet.
                let labelled = (try? c.decodeIfPresent(String.self, forKey: .kind))
                    .flatMap { $0 }
                let kind = labelled.flatMap(WordKind.init(rawValue:))
                let unreadableKind = kind == nil ? labelled : nil
                let old = try c.decodeIfPresent([String].self, forKey: .heard) ?? []
                let listed = try c.decodeIfPresent([Pronunciation].self, forKey: .pronunciations) ?? []
                // Both keys, joined. They are the same list with different
                // amounts known about each entry, and dropping one because the
                // other exists is how a migration eats data.
                //
                // The new key first, so a rendering written both ways keeps the
                // entry that knows something about itself. Registered twice it
                // would be two search targets for one sound, and a term's
                // spotter score is the best of its targets — a duplicate is a
                // free extra draw.
                let said = Self.distinct(listed + old.map { Pronunciation(heard: $0) })
                let wroteHeard = !old.isEmpty
                // Number first. Yams answers `Bool.self` for `0.85` quite
                // happily — anything that is not `true`/`yes`/`on` decodes as
                // `false` — so asking about `off` before asking about the
                // number read every measured floor as `floor: off` and dropped
                // the term from sound matching entirely. Silently: a term that
                // is merely never matched still loads.
                //
                // The reverse trap does not exist. `off` is not a number, so
                // asking for a Float first throws and falls through.
                if let number = (try? c.decodeIfPresent(Float.self, forKey: .floor)) ?? nil {
                    self.init(offerBelow: number, pronunciations: said, kind: kind,
                              unreadableKind: unreadableKind, wroteHeard: wroteHeard)
                    return
                }
                // `off` rather than a magic number. The previous spelling was
                // `1.0`, which reads as maximum strictness and meant the
                // opposite — never fire at all.
                // `off` is a YAML 1.1 boolean, not a string — as are `on`,
                // `yes` and `no`. Written as `floor: off` it arrives here as
                // `false`, and reading it only as a string threw, which took
                // the whole file down silently.
                if let flag = (try? c.decodeIfPresent(Bool.self, forKey: .floor)) ?? nil {
                    self.init(
                        offerBelow: nil, never: flag == false,
                        pronunciations: said, kind: kind, unreadableKind: unreadableKind,
                        wroteHeard: wroteHeard
                    )
                    return
                }
                if let word = (try? c.decodeIfPresent(String.self, forKey: .floor)) ?? nil {
                    self.init(
                        offerBelow: nil, never: word.lowercased() == "off",
                        pronunciations: said, kind: kind, unreadableKind: unreadableKind,
                        wroteHeard: wroteHeard
                    )
                    return
                }
                self.init(offerBelow: nil, pronunciations: said, kind: kind,
                          unreadableKind: unreadableKind, wroteHeard: wroteHeard)
            }

            /// One entry per spelling, first kept. Exact rather than
            /// case-insensitive: "Versal" and "versal" tokenise differently and
            /// are two renderings, not one written twice.
            private static func distinct(_ said: [Pronunciation]) -> [Pronunciation] {
                var seen: Set<String> = []
                return said.filter { seen.insert($0.heard).inserted }
            }
        }

        var terms: [String: Term] = [:]

        /// Legacy keys this file was read with, in words, for `notices()`.
        ///
        /// Migration is done here rather than reported here: the file loads
        /// and behaves, and the sentence explaining what to write instead is
        /// printed by whoever prints notices. A file nobody edits by hand
        /// should not fail to load because a key was renamed.
        var legacy: [String] = []

        /// Numbers the file asked for and did not get, in words, for
        /// `problems()`.
        ///
        /// Refused here rather than reported and used. Nothing downstream
        /// re-checks them, so a similarity of 85 would silence the whole
        /// vocabulary on every dictation until somebody happened to run
        /// `--check-config`. The default is kept instead, and the complaint
        /// says which number is actually running.
        var refused: [String] = []

        enum CodingKeys: String, CodingKey {
            case acoustic, terms
            case minSimilarity = "min_similarity"
            case offerBelow = "offer_below"
            case decideAbove = "decide_above"
            case soundBelow = "sound_below"
            case gateRank = "gate_rank"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let on = try c.decodeIfPresent(Bool.self, forKey: .acoustic) {
                acoustic = on
                if on {
                    legacy.append("`acoustic: true` searched the audio for a term"
                        + " with a second model. That pass is gone — names are"
                        + " matched by how they sound, on the text, with no audio."
                        + " The key is read and does nothing")
                }
            }
            // `min_similarity` was the file-level floor that did both jobs. It
            // now does one, so it is read as `offer_below` — the number is
            // kept, the meaning narrows.
            var asked: (key: String, value: Float)?
            if let old = try c.decodeIfPresent(Float.self, forKey: .minSimilarity) {
                asked = ("min_similarity", old)
                legacy.append("`min_similarity: \(old)` is the old name for"
                    + " `offer_below:`, and both are read and do nothing now."
                    + " `sound_below:` is the floor a reading has to clear")
            }
            // Written explicitly it wins, whatever the old key said. A file
            // carrying both is mid-migration and the new key is the intent.
            if let offered = try c.decodeIfPresent(Float.self, forKey: .offerBelow) {
                asked = ("offer_below", offered)
            }
            // A similarity is 0 to 1 and nothing else can be one. Above 1 no
            // reading ever reaches the menu; below 0 every span does. Both are
            // a number in the wrong units, and both look like the vocabulary
            // being broken rather than like a setting.
            if let asked {
                if Self.similarities.contains(asked.value) {
                    offerBelow = asked.value
                } else {
                    refused.append("`\(asked.key): \(asked.value)` is outside 0 to 1 —"
                        + " it is a similarity, where 1.0 is the term spelled exactly."
                        + " Running at \(offerBelow)")
                }
            }
            // Same range as `offer_below`, same reason, and refused the same
            // way: a sound floor outside 0 to 1 silences the whole sound path
            // on every dictation and looks like the feature not working.
            if let sounded = try c.decodeIfPresent(Float.self, forKey: .soundBelow) {
                if Self.similarities.contains(sounded) {
                    soundBelow = sounded
                } else {
                    refused.append("`sound_below: \(sounded)` is outside 0 to 1 —"
                        + " it is a similarity, where 1.0 is the term said exactly."
                        + " Running at \(soundBelow)")
                }
            }
            // `gate_rank` switched a rule that wrote a name when its span read
            // worst in the sentence. The rule is gone — see `SlotGate` — so the
            // key is read and says so rather than being ignored in silence.
            if try c.decodeIfPresent(Bool.self, forKey: .gateRank) != nil {
                legacy.append("`gate_rank:` switched a rule that wrote a name"
                    + " because its span read worst in its sentence. That rule is"
                    + " gone: over 150 real decisions it wrote 27 names and 17"
                    + " were wrong. The key is read and does nothing")
            }
            // Nats, and the audio arguing against a reading by a negative
            // amount is the audio agreeing with it. At or below 0 every
            // proposal the decoder does not already prefer is dropped before
            // anyone sees it.
            if let decided = try c.decodeIfPresent(Float.self, forKey: .decideAbove) {
                legacy.append("`decide_above:` weighed a reading against the audio,"
                    + " and there is no audio to weigh it against any more."
                    + " The key is read and does nothing")
                if decided > 0 {
                    decideAbove = decided
                } else {
                    refused.append("`decide_above: \(decided)` would drop every reading"
                        + " the audio does not already prefer — it is a margin in nats,"
                        + " and it has to be above 0. Running at \(decideAbove)")
                }
            }
            terms = try c.decodeIfPresent([String: Term].self, forKey: .terms) ?? [:]

            // The same range, one level down. A legacy per-term floor is still
            // a similarity, and one in the wrong units takes only its own term
            // out of reach — which is worse than the file-level case, because
            // the rest of the vocabulary goes on working and hides it.
            let wrong = terms
                .filter { _, entry in entry.offerBelow.map { !Self.similarities.contains($0) } ?? false }
                .keys.sorted()
            for name in wrong { terms[name]?.offerBelow = nil }
            if !wrong.isEmpty {
                refused.append("`floor:` on \(wrong.joined(separator: ", ")) is outside"
                    + " 0 to 1 — it is a similarity, where 1.0 is the term spelled"
                    + " exactly. Running those at \(offerBelow)")
            }

            let floored = terms.filter { $0.value.offerBelow != nil }.keys.sorted()
            if !floored.isEmpty {
                legacy.append("a per-term `floor:` number on"
                    + " \(floored.joined(separator: ", ")) is read and does"
                    + " nothing now — `sound_below:` at the top of the file is"
                    + " the one floor. `floor: off` is unaffected and still"
                    + " means never matched by sound")
            }

            // `heard:` is the old key for the same list, and so is a bare list
            // written under the term. Both still load and every rendering still
            // works. What they cannot do is say anything about an entry: a bare
            // string records no count and no provenance, so a file made only of
            // those cannot decide which entries are worth keeping. The line
            // above already says how many are searched for by sound, so this one
            // does not repeat it.
            let wroteHeard = terms.filter { $0.value.wroteHeard }.keys.sorted()
            if !wroteHeard.isEmpty {
                legacy.append("renderings on \(wroteHeard.joined(separator: ", "))"
                    + " are written the old way — a `heard:` list, or a bare list"
                    + " under the term. They still work. The setting is"
                    + " `pronunciations:`, a list of `- heard:` entries each with"
                    + " `seen:` and `from:` (correction, mined or calibration)")
            }

            // A `from:` nobody can read. Not refused — it labels a rendering
            // rather than doing anything, and dropping the rendering over its
            // label would cost the part that works.
            let mislabelled = terms
                .flatMap { name, entry in
                    entry.pronunciations.compactMap { said in
                        said.unreadableFrom.map { "\(name)/\(said.heard): `from: \($0)`" }
                    }
                }
                .sorted()
            if !mislabelled.isEmpty {
                legacy.append("\(mislabelled.joined(separator: ", ")) — not one of"
                    + " correction, mined, calibration, so it is read as legacy")
            }

            // The same for `kind:`, which nothing reads yet — so a typo in it
            // is silent in every other way.
            let miskinded = terms
                .compactMap { name, entry in
                    entry.unreadableKind.map { "\(name): `kind: \($0)`" }
                }
                .sorted()
            if !miskinded.isEmpty {
                legacy.append("\(miskinded.joined(separator: ", ")) — not one of"
                    + " person, place, organization, word, so it is not recorded")
            }
        }

        /// What a similarity may be. FluidAudio's metric is normalised, so
        /// anything outside this is a number in the wrong units.
        private static let similarities: ClosedRange<Float> = 0...1
    }

    /// The terms given to the decoder as acoustic context, each with the
    /// spelling distance at which it is worth offering.
    ///
    /// The file-level `offer_below` unless the term carries a legacy `floor:`
    /// number of its own, which FluidAudio already treats as an override of the
    /// value passed alongside it.
    ///
    /// Short and non-alphabetic terms are dropped. A four-character term
    /// free-start aligns to almost any run of frames, which is what makes short
    /// terms the over-firing ones, and a name carrying a dot or a digit is not
    /// something the decoder could have produced.
    var vocabularyTerms: [(text: String, offerBelow: Float)] {
        vocabulary.terms
            .filter { term, entry in
                !entry.never && term.count >= 5 && term.allSatisfy(\.isLetter)
            }
            .map { ($0.key, $0.value.offerBelow ?? vocabulary.offerBelow) }
            .sorted { $0.0 < $1.0 }
    }

    /// The exact rules the vocabulary file contributes. Flattened the same way
    /// `transcription.replacements` is, so the substitution pass takes both and
    /// never needs to know which file a rule came from.
    ///
    /// Every pronunciation is still a rule as well as a sound. The two catch
    /// different things — a rule fires on a spelling wherever it appears, the
    /// spotter fires where the audio agrees — and dropping the rules would
    /// change what the pipeline sees on every clip. It is a measurement of its
    /// own, not a side effect of adding the sound.
    var vocabularyRules: [Transcription.Rule] {
        vocabulary.terms
            .flatMap { term, entry in
                entry.heard.map { Transcription.Rule(source: $0, replacement: term) }
            }
            .sorted { $0.source < $1.source }
    }

    /// The pronunciations that will be searched for in the audio, with the
    /// term each one reports.
    ///
    /// Only for terms the pass already searches for. A pronunciation is
    /// registered under its *term's* name, so one attached to a term that has
    /// no entry of its own would make the spotter report a term with no token
    /// count, no floor and no place in `vocabularyTerms` — a finding nothing
    /// downstream can price. That is the real rule behind the prototype's
    /// silent `name.count >= 5` skip, which was the same test written as a
    /// number.
    var vocabularyPronunciations: [(term: String, heard: String)] {
        let searched = Set(vocabularyTerms.map(\.text))
        return vocabulary.terms
            .filter { searched.contains($0.key) }
            .flatMap { name, entry in entry.pronunciations.map { (term: name, heard: $0.heard) } }
            .sorted { ($0.term, $0.heard) < ($1.term, $1.heard) }
    }

    /// Every spelling that stands for a term by ear, with its sound where the
    /// file writes one down.
    ///
    /// The term itself first, then each of its renderings. A rendering is a
    /// sound the speaker's mouth actually produces, so it reaches words the
    /// term's own spelling cannot: `Silberstein` is 0.90 from the rendering
    /// `Silverstein` and 0.56 from `Zylbersztejn`.
    ///
    /// **`floor: off` is honoured and every other filter is not.**
    /// `vocabularyTerms` also drops short terms and terms with a space in
    /// them, because the spotter needs CTC tokens for each and reports a term
    /// nothing downstream can price otherwise. Nothing here goes near the
    /// spotter, and the terms those rules drop are exactly the ones this
    /// catches: `Claude Code` from "cloth code", `red rock` from "bedrock".
    var vocabularySounds: [(term: String, form: String, phonemes: String?)] {
        vocabulary.terms
            .filter { !$0.value.never }
            .flatMap { name, entry -> [(term: String, form: String, phonemes: String?)] in
                [(name, name, nil)]
                    + entry.pronunciations.map { (name, $0.heard, $0.phonemes) }
            }
            .sorted { ($0.term, $0.form) < ($1.term, $1.form) }
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
        var returnsJSON = false
        var body: Transform.Body?
        var folder: TransformFolder?
        var timeout: Double?
        /// Where the body was read from, for a `prompt:` or `replace:` written
        /// as `{ path: … }`. Nil for an inline one.
        var source: TransformFolder.Resolved?
        /// More than one of `prompt:`, `replace:` and `command:` on one entry.
        var namesBoth = false
        /// A `path:` that named a file this could not read, in words.
        var unreadable: String?
        /// `tests: { path: heldout.yaml }` — the set `--eval` scores by default.
        var tests: String?
        /// `offer: true` — put this on the pill after a dictation.
        var offer = false
        /// `key: f` — the letter shown on its chip.
        var offerKey = ""
        /// `say: [slack handles, handles]` — what to call it out loud.
        var say: [String] = []
        /// `model: gpt`, or `model: { use: gpt, reasoning: low }`.
        var model: ModelRef?

        enum CodingKeys: String, CodingKey {
            case name, description, display, confirm, prompt, content, replace, command
            case tests, returns, offer, model, say
            case offerKey = "key"
            case timeout = "timeout_seconds"
        }

        /// The mapping form of a body: `prompt: { path: slack.md }`.
        ///
        /// A scalar stays a scalar — an inline `prompt: |` is unchanged, and a
        /// three-line prompt is worse in a file than in the config it belongs
        /// to. This is for the ones long enough to want an editor of their own.
        private struct BodyFile: Decodable {
            var path: String
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func trimmed(_ key: CodingKeys) throws -> String {
                (try c.decodeIfPresent(String.self, forKey: key) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            /// The `path:` of a body written as a mapping, or nil when the key
            /// is absent or holds a scalar.
            func path(_ key: CodingKeys) -> String? {
                guard let file = try? c.decodeIfPresent(BodyFile.self, forKey: key) else {
                    return nil
                }
                let written = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
                return written.isEmpty ? nil : written
            }
            name = try trimmed(.name)
            description = try trimmed(.description)
            display = try trimmed(.display)
            if let directory = decoder.userInfo[.configDirectory] as? URL {
                folder = TransformFolder(configDirectory: directory, name: name)
            }
            confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? true
            timeout = try c.decodeIfPresent(Double.self, forKey: .timeout)
            // `returns: json`, spelled as a word rather than as `returns_json:
            // true`, because the thing being named is a protocol and there may
            // one day be a second one. Anything else is refused rather than
            // read as false: `returns: JSON` and `returns: text` both look like
            // they say something, and a key that quietly means nothing is how a
            // script ends up talking past the app that runs it.
            if let declared = try c.decodeIfPresent(String.self, forKey: .returns) {
                let written = declared.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                returnsJSON = written == "json"
                if !returnsJSON, written != "text" {
                    unreadable = "returns: \(declared) — write `returns: json`, or leave it out"
                }
            }
            // Written either way — `tests: heldout.yaml` and
            // `tests: { path: heldout.yaml }` mean the same thing — and
            // refused when it is neither. A mapping
            // that is not `{ path: … }` — `tests: { file: heldout.yaml }` —
            // used to decode as nothing at all, and the transform then scored
            // `cases.yaml` while the config said otherwise. A key that does
            // not do what it says is worse than one that fails.
            if let written = path(.tests) {
                tests = written
            } else if let scalar = try? trimmed(.tests) {
                tests = scalar.isEmpty ? nil : scalar
            } else {
                unreadable = "`tests:` is neither a filename nor `{ path: <filename> }`"
            }

            // `try?` because a `model:` this cannot read is one setting gone
            // wrong, not a transform worth dropping: it then runs on the
            // default model, which is what it did before the key existed.
            // `--check-config` names anything the mapping got wrong.
            model = (try? c.decodeIfPresent(ModelRef.self, forKey: .model)) ?? nil

            offer = try c.decodeIfPresent(Bool.self, forKey: .offer) ?? false
            // One letter, upper case. The chip draws it as a keycap and a
            // keycap holds one character; a key is printed in capitals whatever
            // the config wrote it as.
            offerKey = String(try trimmed(.offerKey).prefix(1)).uppercased()
            // One string or a list, because most transforms want one alias and
            // writing `say: bullets` should not be an error.
            //
            // Absent and unreadable are told apart. Both used to answer with an
            // empty list, so `say: 42` left the transform in the catalogue with
            // no alias — and the only symptom was that the words you had put
            // there stopped reaching it, which is a routing bug to chase rather
            // than a config line to fix. `--check-config` names it now.
            if c.contains(.say) {
                if let one = try? c.decode(String.self, forKey: .say) {
                    say = [one]
                } else if let listed = try? c.decode([String].self, forKey: .say) {
                    say = listed
                } else {
                    unreadable = "has a `say:` that is neither a word nor a list of words"
                }
            }
            say = say.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // A body written either way. The mapping is tried first and only
            // succeeds on `{ path: <string> }`, so nothing that decoded before
            // decodes differently now: a table whose one entry happens to be
            // `path: [chemin]` is an array and falls through to the table, and
            // a malformed table still throws where it always did rather than
            // quietly arriving as an entry with no body.
            let promptPath = path(.prompt) ?? path(.content)
            let instructions = promptPath == nil
                ? (try trimmed(.prompt).isEmpty ? trimmed(.content) : trimmed(.prompt))
                : ""
            let tablePath = path(.replace)
            let table = tablePath == nil
                ? try c.decodeIfPresent([String: [String]].self, forKey: .replace)
                : nil
            let command = try trimmed(.command)

            namesBoth = [
                !instructions.isEmpty || promptPath != nil,
                table != nil || tablePath != nil,
                !command.isEmpty
            ].filter { $0 }.count > 1

            // Assigned through a local rather than into `unreadable` directly.
            // The tuple form overwrote whatever was already there, so a
            // malformed `tests:` was erased the moment the body happened to
            // read successfully — and the entry was then kept, scoring
            // `cases.yaml` while the config said otherwise. The first reason
            // an entry cannot be used is the one worth reporting; a body that
            // is fine has nothing to say about a key that is not.
            var bodyProblem: String?
            if !command.isEmpty {
                body = .command(command)
            } else if let table {
                body = .replace(table)
            } else if !instructions.isEmpty {
                body = .prompt(instructions)
            } else if let promptPath {
                (body, source, bodyProblem) = readPrompt(promptPath)
            } else if let tablePath {
                (body, source, bodyProblem) = readTable(tablePath)
            }
            unreadable = unreadable ?? bodyProblem
        }

        /// A prompt file, read verbatim. No front matter, no templating: what is
        /// in the file is what the model is told, and a format to learn between
        /// the two is a format to get wrong.
        private func readPrompt(_ path: String)
            -> (Transform.Body?, TransformFolder.Resolved?, String?) {
            guard let found = folder?.resolve(path) else {
                return (nil, nil, "prompt: no file at \(path)")
            }
            guard let text = try? String(contentsOf: found.url, encoding: .utf8) else {
                return (nil, nil, "prompt: could not read \(found.path)")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return (nil, nil, "prompt: \(found.path) is empty")
            }
            return (.prompt(trimmed), found, nil)
        }

        /// A `replace:` file holds the same mapping the inline table would.
        private func readTable(_ path: String)
            -> (Transform.Body?, TransformFolder.Resolved?, String?) {
            guard let found = folder?.resolve(path) else {
                return (nil, nil, "replace: no file at \(path)")
            }
            guard let text = try? String(contentsOf: found.url, encoding: .utf8) else {
                return (nil, nil, "replace: could not read \(found.path)")
            }
            guard let table = try? YAMLDecoder().decode([String: [String]].self, from: text) else {
                return (nil, nil, "replace: \(found.path) is not a table of"
                    + " `wanted: [heard, heard]`")
            }
            return (.replace(table), found, nil)
        }
    }

    /// A `transforms:` section, wherever it is written.
    ///
    /// Exposed so a `--pipeline` fixture can carry one and have it read by the
    /// type that reads the real thing, rather than by a second parser that
    /// would be free to disagree about what a transform is.
    static func transforms(from decoder: Decoder) throws -> [Transform] {
        assembled(try [TransformEntry](from: decoder)).kept
    }

    /// The entries worth keeping, with a line in the log for each that is not.
    ///
    /// An entry with no name, or with no body to run, cannot be routed to or
    /// run, and dropping it silently is how a typo becomes an evening. Reported
    /// rather than thrown, so one bad entry does not cost you the rest.
    ///
    /// `unreadable` comes back separately because one of these reasons is not
    /// like the others. An entry naming no body is a half-written config; an
    /// entry whose `path:` points at a file that is not there is a config that
    /// says exactly what it wants and cannot have it, and a log line is not
    /// enough for the difference between "the stage does nothing" and "the
    /// stage is not there" — so `--check-config` gets to say it too.
    private static func assembled(
        _ entries: [TransformEntry]
    ) -> (kept: [Transform], unreadable: [String]) {
        var kept: [Transform] = []
        var unreadable: [String] = []
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
            if let why = entry.unreadable {
                let said = "transforms: \"\(entry.name)\" \(why); skipped"
                Log.write(said)
                unreadable.append(said)
                continue
            }
            // A name the scope already uses. Dropped rather than reported and
            // kept, because a stage files its variables under its own name and
            // this one would write over `lists.determiners` or `asr.confidence`.
            //
            // Asked here, where the name is declared, because `Pipeline
            // .validate` asks it of the spelling a *step* wrote and the two are
            // not the same question. And asked case-insensitively, because
            // `transform(named:)` is: a step spelled `lists` reaches a transform
            // declared `Lists`, and `Pipeline.namespace` then files it under the
            // step's spelling. Either casing is a way into the same namespace,
            // so neither may be declared.
            if let taken = Scope.reserved.first(where: {
                $0.caseInsensitiveCompare(entry.name) == .orderedSame
            }) {
                let said = "transforms: \"\(entry.name)\" would file its variables where"
                    + " \(taken) already is; skipped — rename it"
                Log.write(said)
                unreadable.append(said)
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
                folder: entry.folder, timeout: entry.timeout,
                confirm: entry.confirm, returnsJSON: entry.returnsJSON,
                offer: entry.offer, offerKey: entry.offerKey, say: entry.say,
                body: body, source: entry.source,
                tests: entry.tests, model: entry.model
            ))
        }
        return (kept, unreadable)
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
        /// The folder this transform owns — `transforms/<name>/` beside the
        /// config that declared it — which is what a relative path is resolved
        /// against and the working directory a `command:` runs in. Nil when it
        /// was not decoded from a file: a default, or a test.
        var folder: TransformFolder?
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
        /// Whether a `command:` speaks the structured protocol — `{text, ctx}`
        /// in, `{text?, vars?}` out — rather than plain text on stdin and stdout.
        ///
        /// Declared rather than detected. Reading the output to decide would
        /// break on the one transcript most likely to arrive in a folder with a
        /// `code_identifiers` stage in it: a sentence that *is* a JSON object.
        /// It would also make a script's protocol depend on its answer, so a
        /// stage would change contract on one sentence in a thousand and nowhere
        /// else.
        ///
        /// Off by default, and off is the whole of the old contract: stdout is
        /// the transcript, `sed` is still a transform, and nothing anybody has
        /// already written has to change.
        var returnsJSON: Bool = false
        /// Whether this gets a chip on the pill after a dictation, next to
        /// Correct.
        ///
        /// Off by default. The offer is on screen for a few seconds and every
        /// entry costs the others room, so a transform joins it only by asking
        /// — it holds what you reach for without thinking, not every transform
        /// a config happens to define.
        var offer: Bool = false
        /// The letter shown on that chip. Empty when the config named none; the
        /// chip is still there and still clickable.
        var offerKey: String = ""
        /// What to call this out loud, besides its name.
        ///
        /// A name is written for a config file — `slack_handles`, `code_identifiers` — and nobody says an underscore. An alias is what you would actually
        /// ask for, and it is the difference between a script the keyed path
        /// can reach without a model and one it cannot reach at all.
        ///
        /// Only the keyed path reads these. `"hey parrot"` goes to the router,
        /// where a `description` is the thing written to be matched against.
        var say: [String] = []
        var body: Body
        /// Where the body was read from, when it was read from a file at all —
        /// `prompt: { path: slack.md }`. Nil for an inline body, and nil for a
        /// `command:`, whose file is resolved at the moment it runs because
        /// where the arguments begin is a question only the file system can
        /// answer. `--check-config` prints it: a prompt present both in the
        /// folder and beside the config is otherwise invisible, and "which one
        /// is running" is the first question when something is wrong.
        var source: TransformFolder.Resolved?
        /// The case set `--eval <name>` scores this against, when it is not the
        /// `cases.yaml` every folder has by convention. Relative to the folder,
        /// like everything else a transform names.
        var tests: String?
        /// Which model this prompt runs on, and what it changes about it.
        ///
        /// Nil is `llm.default`, which is what nearly every transform wants.
        /// A `replace:` or `command:` transform asks no model anything, so it
        /// is meaningless there and `--check-config` says so.
        var model: ModelRef?

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

        /// What the menu bar says while this runs, or the transform's own name
        /// when nothing was written — see `Prompt.progressLabel`.
        var progressLabel: String {
            Self.label(display) ?? "\(name)…"
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

        /// Where this transform's body came from on disk, resolved absolute, or
        /// nil when it is written inline — or is a bare `sed` for the shell to
        /// find on PATH, which is a command that runs and has no file.
        ///
        /// A `command:` is resolved here and now rather than at decode time.
        /// Where the program ends and its arguments begin is a question only
        /// the file system can answer, and the answer changes the moment a
        /// script is created: a config loaded before you wrote the file must
        /// not go on insisting it is missing.
        var resolvedSource: TransformFolder.Resolved? {
            if case .command(let command) = body {
                return CommandRunner.parts(of: command, in: folder).resolved
            }
            return source
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

        /// The transform-shaped view, for the catalogue — which now holds
        /// transforms rather than prompts, and has to be able to hold the
        /// free-form one too. It is a prompt that no config declares.
        ///
        /// `model:` is what `commands.catch_all` binds. A prompt no config
        /// declares can carry no `model:` of its own, so the caller passes the
        /// one the config named for it.
        func asTransform(model: ModelRef? = nil) -> Transform {
            var made = Transform(
                name: name, description: description, display: display,
                confirm: confirm, body: .prompt(content)
            )
            made.model = model
            return made
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
    /// Not a polling interval — the check itself is hourly. This is a waiting
    /// period, and it is the only defence a one-person project has against its
    /// own release pipeline being taken: a bad release that is noticed and
    /// pulled inside the window is one nobody's app ever offered. See
    /// `Updates` for why that is worth a setting.
    struct UpdatePolicy: Codable, Equatable {
        /// Negative never asks GitHub at all. Zero takes a release the day it
        /// is published. Anything else waits that many days.
        ///
        /// Zero by default, which is what `config.example.yaml` has always
        /// shipped — the two disagreed, so a config with no `updates:` block
        /// waited a week and a config seeded from the example did not. Anyone
        /// who wants the waiting period sets it; see the note above for what
        /// it is for.
        var afterDays: Int = 0

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

    /// Which model runs what, and the Ollama one this key used to be.
    ///
    /// `model:`, `endpoint:`, `timeout_seconds:` and `keep_loaded:` are the
    /// whole of the old key and still read exactly as they did: together they
    /// define a model named `local`, which is what everything points at when
    /// nothing says otherwise. A config written before `models:` existed is
    /// unchanged by all of this.
    ///
    /// `router` and `vocabulary` are named separately because they are not
    /// like the others: they run on every dictation, they are what you wait
    /// on with the pill on screen, and they carry your transcript. Local is
    /// the right answer for both far longer than it is for a rewrite.
    /// Retired. Decoded only to notice that a config still carries `llm:`, so
    /// `problems` can refuse it and name what replaced each key. Nothing reads
    /// a value out of it.
    struct LLM: Codable, Equatable {
        var enabled: Bool = true
        var model: String = "gemma4:e4b-mlx"
        var endpoint: String = "http://localhost:11434"
        var timeoutSeconds: Double = 20
        /// Load the model at launch and pin it in Ollama's memory. Trades a few
        /// GB of RAM for corrections that answer in 1–2s instead of 7–10s.
        var keepLoaded: Bool = true
        /// The model a transform runs on when it names none. Empty means
        /// `local` — the one `model:` above describes.
        var defaultModel: String = ""
        /// The model behind "hey parrot, …". Empty means `default`.
        var router: String = ""
        /// The model behind the vocabulary judge. Empty means `default`.
        var vocabulary: String = ""

        enum CodingKeys: String, CodingKey {
            case enabled, model, endpoint, router, vocabulary
            case defaultModel = "default"
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
            if let v = try c.decodeIfPresent(String.self, forKey: .defaultModel) { defaultModel = v }
            if let v = try c.decodeIfPresent(String.self, forKey: .router) { router = v }
            if let v = try c.decodeIfPresent(String.self, forKey: .vocabulary) { vocabulary = v }
        }
    }

    /// Which job a call belongs to, for `model(for:)`.
    enum ModelJob: Equatable {
        /// A transform, the free-form prompt, a correction — anything the
        /// speaker asked for by name.
        case general
        /// "hey parrot, …", said before anything else and waited on.
        case router
        /// The KEEP/REVERT judge. Bound on the pipeline stage that runs it,
        /// not here — see `Pipeline.Step.review`.
        case vocabulary
        /// Reading a rule out of a spoken spelling.
        case spelling
    }

    /// What the activation phrase can reach, and which model does each part.
    ///
    /// The router picks a capability; `spelling` and `catch_all` are two of the
    /// things it can pick. All three are the spoken-command path, so they bind
    /// here rather than under a key named after the technology.
    ///
    /// A model named nowhere runs on the default — the one entry in `models:`
    /// carrying `default: true`.
    struct Commands: Decodable, Equatable {
        /// Matching what you said to a capability. Runs on every "hey parrot",
        /// and it is what you wait on with the pill on screen.
        var router: String = ""
        /// Reading a rule out of "Tasmin spells T A S M E E N". A built-in, so
        /// it can carry no `model:` of its own the way a transform can.
        var spelling: String = ""
        /// The instruction no capability covers — "use the 24 hour clock".
        ///
        /// `false` refuses them instead. It was `free_form:` at the top level,
        /// and it is here because it is one of the router's answers rather than
        /// a setting of its own.
        var catchAll: ModelRef? = ModelRef()
        /// Whether the catch-all is allowed at all.
        var catchAllEnabled = true

        enum CodingKeys: String, CodingKey {
            case router, spelling
            case catchAll = "catch_all"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let v = try c.decodeIfPresent(String.self, forKey: .router) { router = v }
            if let v = try c.decodeIfPresent(String.self, forKey: .spelling) { spelling = v }
            // Three spellings, because the key answers two questions at once:
            // whether the catch-all runs, and what it runs on. `false` is the
            // only one that turns it off.
            if let on = ((try? c.decodeIfPresent(Bool.self, forKey: .catchAll)) ?? nil) {
                catchAllEnabled = on
                catchAll = on ? ModelRef() : nil
            } else if let ref = try c.decodeIfPresent(ModelRef.self, forKey: .catchAll) {
                catchAll = ref
                catchAllEnabled = true
            }
        }
    }

    /// Every model this config can reach, by name.
    ///
    /// Only what `models:` defines. There is no implicit entry.
    ///
    /// `llm:` used to describe one Ollama model called `local`, and everything
    /// fell back to it. A model you cannot see in the file is a model nobody
    /// can reason about — it read as the app's own rather than as yours, and
    /// it was built from this struct's defaults on a config that named no
    /// Ollama model at all. `llm:` is refused now; see `Config.problems`.
    var modelsByName: [String: ModelSpec] { models }

    func model(named name: String) -> ModelSpec? {
        modelsByName[name.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// The name everything falls back to: the entry carrying `default: true`,
    /// or the only entry there is.
    ///
    /// One model needs no flag — there is nothing to choose between. Several
    /// with none marked is refused rather than guessed at, so this returning
    /// the first sorted name is a value for the error path to print, not a
    /// choice anybody relies on.
    var defaultModelName: String {
        let all = modelsByName
        if let claimed = all.values.filter(\.isDefault).map(\.name).sorted().first {
            return claimed
        }
        if all.count == 1, let only = all.keys.first { return only }
        return all.keys.sorted().first ?? ""
    }

    /// The name a job runs under when nothing overrides it.
    func modelName(for job: ModelJob) -> String {
        func written(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fallback = defaultModelName
        switch job {
        case .general: return fallback
        case .router: return written(commands.router).isEmpty ? fallback : written(commands.router)
        case .spelling:
            return written(commands.spelling).isEmpty ? fallback : written(commands.spelling)
        case .vocabulary:
            return fallback
        }
    }

    /// The model a call runs on: what the call site named, else what the job
    /// is bound to, else `local`.
    ///
    /// A name nothing defines falls back rather than failing. `--check-config`
    /// refuses it by name, and a typo costing you the default model is better
    /// than a typo costing you the sentence.
    func model(for job: ModelJob = .general, override: ModelRef? = nil) -> ModelSpec {
        let all = modelsByName
        let asked = (override?.use).flatMap { $0.isEmpty ? nil : all[$0] }
        let base = asked ?? all[modelName(for: job)] ?? all["local"] ?? ModelSpec()
        return base.applying(override)
    }

    /// The model a transform's prompt runs on.
    func model(for transform: Transform) -> ModelSpec {
        model(for: .general, override: transform.model)
    }

    /// Everything `models:` and the keys pointing into it get wrong.
    func modelProblems() -> [String] {
        var found: [String] = []
        let all = modelsByName
        for name in all.keys.sorted() {
            guard let spec = all[name] else { continue }
            found += spec.refused.map { "models.\(name): \($0)" }
            if spec.model.isEmpty {
                found.append("models.\(name): no `model:` — nothing says what to ask for")
            }
            guard !spec.api.isLocal else { continue }
            if !spec.key.isSet {
                found.append("models.\(name): `api: \(spec.api.rawValue)` needs an `api_key:`")
            } else if spec.key.resolve() == nil {
                let fix = spec.key.kind == .keychain
                    ? " — add one with `--set-key \(name)`" : ""
                found.append("models.\(name): no key at \(spec.key.described)\(fix)")
            }
        }
        let names = all.keys.sorted().joined(separator: ", ")
        for (key, written) in [
            ("commands.router", commands.router), ("commands.spelling", commands.spelling),
        ] {
            let name = written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, all[name] == nil else { continue }
            found.append("\(key): no model named \"\(name)\" — have: \(names)")
        }
        // The third binding, and the only one that is a `ModelRef` rather than
        // a bare name, so it can also carry what only a `models:` entry may
        // say. Unchecked, a typo here costs the model you chose the catch-all
        // for — the one case that most wants a model of its own.
        if let ref = commands.catchAll {
            found += ref.rejected.map { "commands.catch_all: \($0)" }
            let name = ref.use.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, all[name] == nil {
                found.append("commands.catch_all: no model named \"\(name)\" — have: \(names)")
            }
        }

        // Which model everything falls back to. One entry needs no flag —
        // there is nothing to choose between — so this only speaks up when
        // there is a choice and the file does not make it, or makes it twice.
        let claimed = all.values.filter(\.isDefault).map(\.name).sorted()
        if claimed.count > 1 {
            found.append("models: \(claimed.joined(separator: " and ")) both say"
                + " `default: true` — exactly one may")
        } else if claimed.isEmpty, all.count > 1 {
            found.append("models: none says `default: true`, and there are"
                + " \(all.count) to choose from — put it on the one that should"
                + " run what names no model: \(names)")
        }
        for transform in transforms {
            guard let ref = transform.model else { continue }
            found += ref.rejected.map { "transforms.\(transform.name).model: \($0)" }
            let name = ref.use.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, all[name] == nil {
                found.append("transforms: \"\(transform.name)\" names model \"\(name)\","
                    + " which `models:` does not define — have: \(names)")
            }
            if !transform.isPrompt {
                found.append("transforms: \"\(transform.name)\" has a `model:` and never"
                    + " asks a model anything — only a `prompt:` does")
            }
        }
        return found
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

        /// When a period the transcriber wrote is taken out again — see
        /// `SentenceJoin`.
        ///
        ///     sentences: false        never look at a boundary
        ///     sentences:
        ///       join_below: -4.0      remove the period, say nothing
        ///       offer_below: -2.0     offer the join, do not write it
        ///
        /// Two spellings, like `review:` on a pipeline step: a bare `false`
        /// turns the stage off, anything else says what it runs with.
        ///
        /// The defaults are where the score was measured, over 194 real
        /// periods and 130 synthetic cuts of this speaker's own dictation. -4
        /// repaired 32% of the cuts and joined no real period; -2 repaired 55%
        /// and joined 1.2 per 100. So -4 writes and -2 asks.
        var sentences: Sentences = Sentences()

        struct Sentences: Decodable, Equatable {
            var enabled = true
            var joinBelow: Double = -4
            var offerBelow: Double = -2

            enum CodingKeys: String, CodingKey {
                case joinBelow = "join_below"
                case offerBelow = "offer_below"
            }

            init() {}

            init(from decoder: Decoder) throws {
                if let on = try? decoder.singleValueContainer().decode(Bool.self) {
                    enabled = on
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                joinBelow = try c.decodeIfPresent(Double.self, forKey: .joinBelow) ?? joinBelow
                offerBelow = try c.decodeIfPresent(Double.self, forKey: .offerBelow) ?? offerBelow
                // Read in this order, so the two swapped make every offer a
                // silent join instead of refusing the file.
                guard joinBelow < offerBelow else {
                    throw ConfigError.invalidValue(
                        key: "transcription.sentences.join_below",
                        value: "\(joinBelow), against offer_below \(offerBelow)",
                        expected: "a number below offer_below — joining is the surer tier,"
                            + " so its threshold is the lower one"
                    )
                }
            }
        }

        enum InsertMode: String, Codable, Equatable {
            case paste
            case clipboard
        }

        enum CodingKeys: String, CodingKey {
            case enabled, replacements, pipeline, languages, sentences
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
            // Retired into the pipeline. Still read, only so that a config
            // carrying them can be told so — see `retired`.
            case numbers
            case fuzzyMatching = "fuzzy_matching"
            // The map keyed by language that `pipeline:` replaced.
            case pipelines
        }
        /// Grouped by the word you want written, since one name accumulates
        /// several mishearings — eleven rules had built up for four names
        /// before this was grouped.
        ///
        ///     replacements:
        ///       Tasmeen: [Tasmid, Tasmin, Tasmine]
        var replacements: [String: [String]] = [:]
        /// What a finished transcript goes through, in order — see `Pipeline`.
        ///
        /// Nil here means the config said nothing, not that nothing should
        /// run: `Pipeline.resolved(config:)` decides that. A new install is
        /// written with every stage listed, so the answer to "what else could
        /// go here" is in the file rather than in the documentation.
        ///
        /// A per-language difference is a condition on the step that differs —
        /// `when: language == "fr"`.
        var pipeline: Pipeline?

        /// Keys this config still carries that no longer do anything.
        ///
        /// `numbers` and `fuzzy_matching` became stages. The decoder ignores
        /// keys it does not know, so a config still setting them would lose
        /// two passes without a word — which is the one outcome a rename must
        /// not have. They are read here purely so `--check-config` can refuse
        /// them and say what to write instead.
        var retired: [String] = []

        /// Stage names in the pipeline that are not stages. Dropped from the
        /// pipeline, kept here: a line silently doing nothing is the same
        /// failure as a retired key, and the log is not where anyone looks.
        var unknownStages: [String] = []

        /// Whether the config still carries `pipelines:`, the map keyed by
        /// language. Nothing under it is read — see `problems()`.
        var legacyPipelines = false

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
        ///
        /// `vocabulary:` names a prompt file rather than a transform, for the
        /// same reason `transform:` names a transform: every entry of that kind
        /// needs the second key, and a form that repeats itself is a form
        /// people mistype.
        ///
        ///     - vocabulary
        ///     - stage: vocabulary
        ///       when: vocabulary.count > 0
        ///       near_misses: false
        ///       by_sound: false
        ///       review: gpt
        ///       max_slots: 4
        struct PipelineEntry: Decodable {
            let name: String
            var transform: String?
            var prompt: String?
            var caps: VocabularyJudge.Caps?
            var nearMisses: Bool?
            var bySound: Bool?
            var gate: Bool?
            var review: String?
            var reviewEnabled: Bool?
            var when: String?
            var unless: String?
            var app: String?
            /// `stage:` and `transform:`/`prompt:`/`vocabulary:` on one entry.
            var namesBoth = false

            private enum CodingKeys: String, CodingKey {
                case stage, transform, prompt, vocabulary, when, unless, app
                case nearMisses = "near_misses"
                case bySound = "by_sound"
                case gate
                case review
                case maxSlots = "max_slots"
                case maxReadings = "max_readings"
                case maxPerSlot = "max_per_slot"
                case maxPerTerm = "max_per_term"
            }

            init(from decoder: Decoder) throws {
                if let bare = try? decoder.singleValueContainer().decode(String.self) {
                    name = bare
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let stage = try c.decodeIfPresent(String.self, forKey: .stage)
                let judged = try c.decodeIfPresent(String.self, forKey: .vocabulary)
                let named = try c.decodeIfPresent(String.self, forKey: .transform)
                    ?? c.decodeIfPresent(String.self, forKey: .prompt)
                if let judged {
                    name = "vocabulary"
                    prompt = judged
                    namesBoth = stage != nil || named != nil
                } else if let named {
                    name = "transform"
                    transform = named
                    // Both keys on one entry is a contradiction, not a
                    // preference to resolve — recorded so the caller refuses it
                    // rather than dropping whichever it liked less.
                    namesBoth = stage != nil
                } else {
                    name = stage ?? ""
                }
                // Read off the resolved name rather than off the `vocabulary:`
                // key, because the key is how the stage used to be spelled and
                // `- stage: vocabulary` is how it is spelled now that there is
                // no file to name.
                if name.caseInsensitiveCompare("vocabulary") == .orderedSame {
                    var caps = VocabularyJudge.Caps.standard
                    // Each optional and each on its own: a person raising one
                    // ceiling should not have to restate the rest.
                    if let slots = try c.decodeIfPresent(Int.self, forKey: .maxSlots) {
                        caps.slots = slots
                    }
                    if let perSlot = try c.decodeIfPresent(Int.self, forKey: .maxPerSlot) {
                        caps.perSlot = perSlot
                    }
                    if let perTerm = try c.decodeIfPresent(Int.self, forKey: .maxPerTerm) {
                        caps.perTerm = perTerm
                    }
                    // Read only so `Caps.problems` can refuse it by name.
                    caps.readings = try c.decodeIfPresent(Int.self, forKey: .maxReadings)
                    self.caps = caps
                    nearMisses = try c.decodeIfPresent(Bool.self, forKey: .nearMisses)
                    bySound = try c.decodeIfPresent(Bool.self, forKey: .bySound)
                    gate = try c.decodeIfPresent(Bool.self, forKey: .gate)
                    // Two spellings, like `catch_all:`: the key says whether
                    // the review runs and what it runs on. `false` is the only
                    // one that turns it off.
                    if let on = ((try? c.decodeIfPresent(Bool.self, forKey: .review)) ?? nil) {
                        reviewEnabled = on
                    } else {
                        review = try c.decodeIfPresent(String.self, forKey: .review)
                    }
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
            // Not `try?`. Swallowing the error leaves joining on with stock
            // thresholds, and a stage that rewrites the transcript must not be
            // reached by a line the file got wrong.
            do {
                if let v = try c.decodeIfPresent(Sentences.self, forKey: .sentences) {
                    sentences = v
                }
            } catch let bad as ConfigError {
                throw bad
            } catch {
                throw ConfigError.invalidValue(
                    key: "transcription.sentences",
                    value: "not a sentence setting",
                    expected: "`false`, or `join_below:` and `offer_below:` as numbers"
                )
            }
            // Wrapped, as `replacements:` is below and for the same reason.
            // Anything thrown here leaves `ConfigStore.load()` entirely, and at
            // launch `loadConfig(announceErrors: false)` swallows it — so one
            // mis-shaped key would drop the whole config back to stock defaults:
            // no replacements, the built-in wake phrase, the default hotkey, in
            // silence.
            do {
                if let entries = try c.decodeIfPresent(
                    [PipelineEntry].self, forKey: .pipeline
                ) {
                    let steps = entries.compactMap { entry -> Pipeline.Step? in
                        guard let stage = Pipeline.stage(named: entry.name) else {
                            unknownStages.append(entry.name)
                            return nil
                        }
                        if entry.namesBoth {
                            // Silently preferring one would delete a stage the
                            // config asked for.
                            contradictoryEntries.append(
                                entry.transform ?? entry.prompt ?? "transform"
                            )
                            return nil
                        }
                        return Pipeline.Step(
                            stage: stage, transform: entry.transform,
                            prompt: entry.prompt, caps: entry.caps,
                            nearMisses: entry.nearMisses, bySound: entry.bySound,
                            gate: entry.gate, review: entry.review,
                            reviewEnabled: entry.reviewEnabled,
                            when: entry.when, unless: entry.unless, app: entry.app
                        )
                    }
                    pipeline = Pipeline(steps: steps)
                }
            } catch {
                throw ConfigError.invalidValue(
                    key: "transcription.pipeline",
                    value: "not a list of steps",
                    expected: "a list of stages — `pipeline: [vocabulary, numbers]`, or one"
                        + " `- ` per line"
                )
            }
            // Detected, never decoded: a value nothing reads cannot be
            // mis-read, whatever shape it is in.
            legacyPipelines = legacy.contains(.pipelines)
            // `try?` on an optional decode gives Bool??, and both layers mean
            // "absent" — flattened here so the condition reads as the question
            // being asked: is the key in the file at all.
            func present(_ key: LegacyKeys) -> Bool {
                ((try? legacy.decodeIfPresent(Bool.self, forKey: key)) ?? nil) != nil
            }
            for key in [LegacyKeys.numbers, .fuzzyMatching] where present(key) {
                retired.append(key.stringValue)
            }
            // Retired, and read only so it can be refused. It held two kinds
            // of rule and neither belongs here any more: a name the recogniser
            // mangles goes in vocabulary.yaml, where it is reviewed in context,
            // and a mechanical rule goes in a transform's `replace:`, which
            // needs no review and already takes regexes, deletions, `{{lists}}`
            // and `when:`/`app:` conditions. Nothing was left in the middle.
            if let container = try? c.decodeIfPresent(
                [String: [String]].self, forKey: .replacements
            ), container != nil {
                retired.append("replacements")
            } else if (try? c.decodeIfPresent([String: String].self, forKey: .replacements))
                ?? nil != nil {
                retired.append("replacements")
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
        /// How long a bare modifier must be held *alone* before it starts a
        /// dictation. ⌘ is half of every shortcut and ⌥ types `#` on a French
        /// layout, so the down edge alone does not mean dictation. Bare
        /// modifiers only; 0 fires on the down edge as before.
        var pressDelaySeconds: Double = 0.18

        enum CodingKeys: String, CodingKey {
            case key, modifiers, mode
            case releaseTailSeconds = "release_tail_seconds"
            case pressDelaySeconds = "press_delay_seconds"
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
            if let delay = try c.decodeIfPresent(Double.self, forKey: .pressDelaySeconds) {
                guard delay >= 0, delay <= 1 else {
                    throw ConfigError.invalidValue(
                        key: "hotkey.press_delay_seconds",
                        value: String(delay),
                        expected: "a delay between 0 and 1 second"
                    )
                }
                self.pressDelaySeconds = delay
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
        /// Decode the clip a second time beside the first, with silence at
        /// both ends, and keep that decode when it reaches further. Off by
        /// default: it recovers a rare failure and costs a second decode.
        ///
        /// The failure is Parakeet skipping frames it never looks at. It
        /// predicts a token and a skip of up to 4 frames of 80ms together, so
        /// one prediction can pass over 320ms of audio. Nothing in the output
        /// says so: timing gap, speech coverage, tokens per second, decoder
        /// confidence and the longest unclaimed stretch of speech were all
        /// measured, and all five put the broken clips inside the healthy
        /// distribution. Padding moves the speech against the frame grid,
        /// which is the only thing that finds it.
        ///
        /// Needs `speech_gate`, which is what reads the clip as samples.
        var secondOpinion: Bool = true

        enum CodingKeys: String, CodingKey {
            case sampleRate = "sample_rate"
            case outputDir = "output_dir"
            case minDurationSeconds = "min_duration_seconds"
            case speechGate = "speech_gate"
            case secondOpinion = "second_opinion"
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
            if let second = try c.decodeIfPresent(Bool.self, forKey: .secondOpinion) {
                self.secondOpinion = second
            }
        }
    }

    struct Feedback: Codable, Equatable {
        /// Play a short system sound on start/stop.
        var sound: Bool = true
        /// How loud those sounds are, from 0 to 1, relative to system volume.
        ///
        /// The system sounds are mixed loud for alerts. Dictation plays them
        /// several times a sentence, so full volume reads as shouting — hence
        /// the low default. Values outside the range are clamped.
        var soundVolume: Float = 0.3
        /// Show the floating recording pill near the bottom of the screen.
        var overlay: Bool = true
        /// After a dictation lands, offer to correct it for a few seconds.
        ///
        /// The pill stays where it is and says which key opens the correction
        /// panel over what was just written. It is the only moment correcting
        /// is cheap — the words are on screen, you are looking at them, and you
        /// have not started typing over them yet. Every other way in costs a
        /// sentence said out loud or a trip to the menu bar.
        ///
        /// Separate from `overlay` on purpose. That one is about watching a
        /// recording happen and some people turn it off as noise; this is about
        /// what to do after one, and wanting one is no reason to want the other.
        var correctOffer: Bool = true
        /// Colour the dictated sentence on the offer, word by word, by how sure
        /// the decoder was of each one.
        ///
        /// Off by default, and it is the one thing on the pill that is about the
        /// app rather than about your words: it puts the whole sentence back on
        /// screen for the length of the offer, which is a lot of pill for something you can
        /// already read where it landed. Worth turning on while you are learning
        /// what your own dictation is weak at — see `Confidence` for what the
        /// colours are anchored to, and why they cannot be anchored to anything
        /// the model documents.
        ///
        /// Needs `correct_offer`. There is no offer to draw it on without one.
        var confidence: Bool = false

        /// When the offer says a dictation is worth a second look.
        ///
        /// On by default, unlike `confidence`, and for the opposite reason: it
        /// costs one line and only on the dictations that earned it, so it is
        /// not a surface you have to want. It needs `correct_offer` for the
        /// same reason the colours do.
        var lowConfidence = LowConfidence()

        /// Whether the warning is armed. Both thresholds have to trip, so
        /// either one at zero turns it off and nothing has to be collected for
        /// it.
        var warnsOnLowConfidence: Bool { lowConfidence.sentence > 0 && lowConfidence.word > 0 }

        /// The two thresholds a dictation is measured against. Both have to
        /// trip — see `Confidence.warning` for why either alone is noise.
        struct LowConfidence: Codable, Equatable {
            /// The decode has to be poor overall: `asr.confidence` below this.
            var sentence: Double = 0.80
            /// And it has to hold a word this bad, ignoring the ones the
            /// vocabulary pass wrote.
            var word: Double = 0.50
            /// How long after a warned dictation a bare Return is taken
            /// instead of typed. Seconds. Zero lets every Return through.
            ///
            /// What this catches is the reflex press — the Return already on
            /// its way down as the words land, before anything has been read.
            /// Past this the press is a decision, and the key goes through even
            /// though the warning is still on screen.
            ///
            /// One key, once, and only on the dictations that raised the
            /// warning. The next Return goes through whatever happens — the tap
            /// disarms itself as it takes the first, so nothing downstream can
            /// hold a keyboard. Bare Return only: ⌘↩ is somebody who knows the
            /// shortcut, and is left alone.
            var holdReturn: Double = 1.5

            /// Zero for either threshold turns the warning off, and the hold
            /// with it — there is nothing to hold a key over.
            init() {}

            enum CodingKeys: String, CodingKey {
                case sentence
                case word
                case holdReturn = "hold_return"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.init()
                if let s = try c.decodeIfPresent(Double.self, forKey: .sentence) {
                    self.sentence = min(max(0, s), 1)
                }
                if let w = try c.decodeIfPresent(Double.self, forKey: .word) {
                    self.word = min(max(0, w), 1)
                }
                if let hold = try c.decodeIfPresent(Double.self, forKey: .holdReturn) {
                    self.holdReturn = max(0, hold)
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case sound
            case soundVolume = "sound_volume"
            case overlay
            case correctOffer = "correct_offer"
            case confidence
            case lowConfidence = "low_confidence"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let sound = try c.decodeIfPresent(Bool.self, forKey: .sound) { self.sound = sound }
            if let volume = try c.decodeIfPresent(Float.self, forKey: .soundVolume) {
                self.soundVolume = min(max(volume, 0), 1)
            }
            if let overlay = try c.decodeIfPresent(Bool.self, forKey: .overlay) { self.overlay = overlay }
            if let offer = try c.decodeIfPresent(Bool.self, forKey: .correctOffer) {
                self.correctOffer = offer
            }
            if let shown = try c.decodeIfPresent(Bool.self, forKey: .confidence) {
                self.confidence = shown
            }
            if let low = try c.decodeIfPresent(LowConfidence.self, forKey: .lowConfidence) {
                self.lowConfidence = low
            }
        }
    }

    /// What gets written to disk about a dictation, apart from the transcript
    /// itself.
    ///
    /// Two switches because the two artifacts have nothing in common but
    /// where they end up. The text log is prose, rotates itself, and is how
    /// every problem in this app gets diagnosed — it stays on. A clip is a
    /// recording of your voice, keeps growing forever, and nothing downstream
    /// needs it once the words have landed — it stays off until you ask for
    /// it, for calibration or for `--transcribe`.
    struct Logging: Codable, Equatable {
        /// The line-by-line log at `~/Library/Logs/ParrotFlow.log` — see
        /// `Log`. On by default.
        var text: Bool = true
        /// Keep each dictation's recording on disk, in `audio.output_dir`.
        /// Off by default: nothing written, nothing left behind.
        var audio: Bool = false

        enum CodingKeys: String, CodingKey { case text, audio }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let v = try c.decodeIfPresent(Bool.self, forKey: .text) { text = v }
            if let v = try c.decodeIfPresent(Bool.self, forKey: .audio) { audio = v }
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
        // Named after the key it was written under, because a spec cannot see
        // its own name and every log line and check prints one.
        if let models = try c.decodeIfPresent([String: ModelSpec].self, forKey: .models) {
            self.models = models.reduce(into: [:]) { out, entry in
                var spec = entry.value
                spec.name = entry.key
                // The name is also the keychain account, and this is the first
                // point at which the spec has one.
                spec.key.adopt(account: entry.key, api: spec.api)
                out[entry.key] = spec
            }
        }
        if let commands = try c.decodeIfPresent(Commands.self, forKey: .commands) {
            self.commands = commands
        }
        if let updates = try c.decodeIfPresent(UpdatePolicy.self, forKey: .updates) {
            self.updates = updates
        }
        if let logging = try c.decodeIfPresent(Logging.self, forKey: .logging) { self.logging = logging }
        // `transforms:` first, then anything still under `prompts:`. Both are
        // read: `prompts:` is what every config written before this existed
        // says, and a rename that silently empties the section is the one
        // outcome a rename must not have.
        var entries = try c.decodeIfPresent([TransformEntry].self, forKey: .transforms) ?? []
        entries += try c.decodeIfPresent([TransformEntry].self, forKey: .prompts) ?? []
        let assembled = Self.assembled(entries)
        transforms = assembled.kept
        unreadableTransforms = assembled.unreadable
        // Read only so `--check-config` can refuse it and name what replaced
        // it. `commands.catch_all` is the setting now.
        if ((try? c.decodeIfPresent(Bool.self, forKey: .freeForm)) ?? nil) != nil {
            retiredKeys.append("free_form")
        }
        if ((try? c.decodeIfPresent(LLM.self, forKey: .llm)) ?? nil) != nil {
            retiredKeys.append("llm")
        }
        // Decoded here because this initialiser is hand-rolled. A property and
        // a CodingKey are not enough: miss this line and the lists work in a
        // `--pipeline` fixture and are empty in the app.
        if let lists = try c.decodeIfPresent([String: [String]].self, forKey: .lists) {
            self.lists = lists
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
    ///
    /// Only faults. What is merely worth knowing goes in `notices()` — see
    /// there for why that had to be a second list after all.

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
        // A pattern naming a list that is not there, or is there and empty.
        // Both are left literal at runtime — an emptied alternation would match
        // everywhere — so the rule simply never fires, and this is the only
        // place that says so.
        let defined = lists.keys.sorted()
        for rule in transcription.rules + transforms.flatMap(\.rules) {
            for name in Config.listNames(in: rule.pattern) {
                guard let words = lists[name] else {
                    found.append("lists: \"\(rule.source)\" names {{\(name)}}, which nothing"
                        + " defines"
                        + (defined.isEmpty ? " — there is no lists: section"
                            : " — have: \(defined.joined(separator: ", "))")
                        + "; the rule never fires")
                    continue
                }
                if words.isEmpty {
                    found.append("lists: \"\(rule.source)\" names {{\(name)}}, which is defined"
                        + " with no words in it; the rule never fires")
                }
            }
        }
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

    /// What a config written for the old shape is told, key by key.
    ///
    /// Not read, not honoured, and not quietly ignored. An unknown key is
    /// dropped by `Decodable` without a word, so a config that still says
    /// `llm:` would load, bind nothing, and look fine until a dictation did
    /// nothing — which is the failure this list exists to prevent.
    private static let movedKeys = [
        "llm": "`llm.default` is now `default: true` on one entry in `models:`;"
            + " `llm.router` and `llm.spelling` are now `commands.router` and"
            + " `commands.spelling`; `llm.vocabulary` is now `review:` on the"
            + " `vocabulary` stage; `llm.enabled` is gone — a config with no"
            + " `models:` calls no model; the four keys that described a model"
            + " are an entry in `models:`",
        "free_form": "now `commands.catch_all`, which also takes the model it"
            + " runs on: `catch_all: gpt`, or `false` to refuse them",
    ]

    func problems() -> [String] {
        var found: [String] = []
        for key in retiredKeys.sorted() {
            found.append("\(key): \(Self.movedKeys[key] ?? "no longer does anything")")
        }
        for key in transcription.retired {
            let said = key == "replacements"
                ? "a name the recogniser mangles goes in vocabulary.yaml, where the"
                    + " `vocabulary` stage reviews it in context; a mechanical rule goes"
                    + " in a transform's `replace:`, which takes regexes, deletions and"
                    + " `{{lists}}` and needs no review"
                : "it is a pipeline stage now"
            found.append("transcription.\(key) no longer does anything — \(said)")
        }
        for name in Set(transcription.unknownStages).sorted() {
            found.append("pipeline: \"\(name)\" is not a stage — have: "
                + Pipeline.stageNames.joined(separator: ", "))
        }
        for name in Set(transcription.contradictoryEntries).sorted() {
            found.append("pipeline: an entry names both `stage:` and `prompt: \(name)`"
                + " — it can be one or the other")
        }
        if transcription.legacyPipelines {
            let running = transcription.pipeline == nil
                ? "no pipeline of yours is running — the built-in default is"
                : "the `pipeline:` list is what runs"
            found.append("transcription.pipelines: is retired and nothing under it is read."
                + " Write one `pipeline:` list, with `when: language == \"fr\"` on a step"
                + " that belongs to one language. Until then \(running)")
        }
        // Numbers `vocabulary.yaml` asked for and did not get. Refused where
        // they were read, so what runs is the default; said here, because a
        // setting that does nothing is exactly what this list is for.
        found += vocabulary.refused.map { "vocabulary: \($0)" }
        found += modelProblems()
        found += replacementProblems()
        // A `path:` that named nothing readable. The entry is gone rather than
        // idle — the pipeline step that names it will say so too — and a
        // spelling mistake in a filename is worth more than a log line.
        found += unreadableTransforms
        // A first word that is still relative after resolution is a bare
        // command name for the shell to find on PATH — `python3`, `sed` — and
        // this cannot say whether that will work. What it can say is that a
        // script sitting right there will not run, which is a fault: the stage
        // is in the pipeline and the transcript comes out untouched.
        for transform in transforms {
            guard case .command(let command) = transform.body,
                  let wrong = CommandRunner.complaint(about: command, in: transform.folder)
            else { continue }
            found.append("transforms: \"\(transform.name)\" cannot run \(command) — \(wrong)")
        }
        // A command that named neither a file in the folder nor anything the
        // shell can find. There is one place a transform's program can be now,
        // so a name that is not there and not on PATH is a mistake rather than
        // an ambiguity — and it is the mistake a config written before folders
        // makes, every time. Left to the shell it fails once per transcript,
        // into the log, while the pipeline goes on returning the text
        // unchanged: the loudest this can be said is here.
        for transform in transforms {
            guard case .command(let command) = transform.body,
                  transform.resolvedSource == nil else { continue }
            let program = String(command.split(separator: " ").first ?? "")
            guard !CommandRunner.onPath(program) else { continue }
            found.append("transforms: \"\(transform.name)\" — \(program) is not in"
                + " transforms/\(transform.name)/, and the shell cannot find it either")
        }
        let pipeline = Pipeline.resolved(config: self)
        for problem in pipeline.validate() {
            found.append("pipeline: \(problem)")
        }
        for step in pipeline.steps where step.stage == .transform {
            guard let name = step.transform, !name.isEmpty else { continue }
            if transform(named: name) == nil {
                found.append("pipeline: no transform named \"\(name)\""
                    + (transforms.isEmpty ? " — `transforms:` is empty"
                        : " — have: \(transforms.map(\.name).joined(separator: ", "))"))
            }
        }
        // `review:` names a model the same way `commands.router` does, and an
        // unresolved one falls back to the default rather than failing.
        for step in pipeline.steps where step.stage == .vocabulary {
            let named = (step.review ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !named.isEmpty, modelsByName[named] == nil else { continue }
            found.append("pipeline: `review: \(named)` names no model — have: "
                + modelsByName.keys.sorted().joined(separator: ", "))
        }
        return found
    }

    /// True things about the config that are worth saying and are not faults.
    ///
    /// A `command:` transform is the one thing in this file that runs code
    /// rather than describing a rewrite, and a config that executes something
    /// you have forgotten about — or that arrived in a config you copied —
    /// should not be able to stay quiet about it. So it is announced on every
    /// load, working or not.
    ///
    /// It was announced through `problems()`, which is where the one list above
    /// stopped being right: `--check-config` prints that list with a ✗ and
    /// exits 1, and the app puts it behind "⚠︎ 1 setting in config.yaml does
    /// nothing" and an alert saying that part of your config is ignored. A
    /// working transform was reported as a broken setting on every launch, and
    /// the answer to "why does it say my config is not working" was that it
    /// wasn't. Announcing is not complaining, and the two cannot share a list
    /// that one end of the app treats as failure.
    func notices() -> [String] {
        var said: [String] = transforms.compactMap { transform in
            guard case .command(let command) = transform.body else { return nil }
            return "transforms: \"\(transform.name)\" runs a program — \(command)"
        }

        // A model that is not on this Mac means your dictation is sent to
        // somebody else's server. Announced on every load for the same reason
        // a `command:` transform is: it is one word in a config file, and the
        // config may not be one you wrote.
        let all = modelsByName
        for name in all.keys.sorted() {
            guard let spec = all[name], !spec.api.isLocal else { continue }
            said.append("models: \"\(name)\" sends text off this Mac — \(spec.url),"
                + " \(spec.model), key from \(spec.key.described)")
        }
        for transform in transforms where transform.isPrompt {
            let spec = model(for: transform)
            guard !spec.api.isLocal else { continue }
            said.append("transforms: \"\(transform.name)\" runs on \(spec.described)")
        }

        // The name judge is a stage now. A pipeline that still names it as a
        // transform keeps working — a `command:` transform is a supported
        // escape hatch and this does not rewrite anybody's config — but it is
        // running the old hand-off, where the positions are re-derived from
        // occurrence counts that no longer hold once a stage edits the text
        // (F10).
        let legacyJudge = Pipeline.resolved(config: self).steps.contains {
            $0.stage == .transform
                && $0.transform?.caseInsensitiveCompare("verify_names") == .orderedSame
        }
        if legacyJudge {
            said.append("pipeline: `- transform: verify_names` is the old name judge."
                + " The app does this itself now — write `- vocabulary`")
        }

        // The vocabulary is learnt rather than written, so it is the part of
        // the configuration nobody remembers the contents of. Printed in full.
        let rules = vocabularyRules.count
        if !vocabulary.terms.isEmpty {
            // Every term that is not `floor: off`, and not the shorter list
            // the audio search could be built for. Nothing tokenises a term
            // any more, so `Claude Code` and `crawl file` are matched by sound
            // like the rest.
            let byEar = Set(vocabularySounds.map(\.term)).sorted()
            said.append("vocabulary: \(vocabulary.terms.count) terms in"
                + " \(ConfigStore.vocabularyURL.lastPathComponent),"
                + " \(byEar.count) matched by sound, \(rules) by rule")
            // What the sound path can reach, which is every term rather than
            // the ones an audio search could be built for. `offer_below` and
            // `decide_above` are not printed: nothing reads them since the
            // acoustic pass was removed, and `notices()` says so instead.
            if !byEar.isEmpty {
                said.append("vocabulary: matched by sound at similarity"
                    + " \(vocabulary.soundBelow) and up, then settled by the"
                    + " free rules or put to the judge")
            }
            let silent = vocabulary.terms
                .filter { $0.value.never && $0.value.pronunciations.isEmpty }
                .keys.sorted()
            if !silent.isEmpty {
                said.append("vocabulary: \(silent.joined(separator: ", ")) —"
                    + " `floor: off` and no pronunciations, so nothing can match them")
            }
        }
        // Said whether or not there are terms: a file can carry the old
        // file-level key and nothing else.
        said += vocabulary.legacy.map { "vocabulary: \($0)" }
        return said
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
    /// `PARROTFLOW_CONFIG_DIR=<path>` — read the config from somewhere else.
    ///
    /// A testing seam, and the only one there is. Everything about a transform
    /// is resolved relative to the config that declared it, so a check script
    /// scoring `--eval` or reading `--check-config` would otherwise be scoring
    /// whatever this machine happens to have configured — which is how
    /// tests/routing-cases.yaml once ended up meaning something on exactly one
    /// laptop. With this, a script can build a whole config directory in /tmp
    /// and run the real binary against it.
    ///
    /// Not a feature for switching profiles: the app reads it too, so a shell
    /// that exports it permanently is a shell that quietly moves your config.
    static let overrideVariable = "PARROTFLOW_CONFIG_DIR"

    static var directory: URL {
        if let overridden = ProcessInfo.processInfo.environment[overrideVariable],
           !overridden.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(
                fileURLWithPath: (overridden as NSString).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AppVariant.configDirectory, isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("config.yaml")
    }

    /// The learnt half. Missing is normal and means an empty vocabulary — it
    /// is written the first time something is learnt, not at install.
    static var vocabularyURL: URL {
        directory.appendingPathComponent("vocabulary.yaml")
    }

    /// Where every transform's folder sits — `TransformFolder` resolves the
    /// same path per transform, from the directory of whichever config
    /// declared it.
    static var transformsDirectory: URL {
        directory.appendingPathComponent("transforms", isDirectory: true)
    }

    /// `<config>/transforms/examples/` — every shipped example, in one
    /// folder, refreshed from `exampleTransformsDirectory` on every launch.
    ///
    /// This folder is the app's, not yours: unlike `transforms/<name>/`,
    /// which is written once and never touched again, this one is
    /// overwritten every time `createIfMissing()` runs, so the shipped
    /// examples never go stale. That is what buys one copy of a script
    /// instead of a copy per transform that uses it —
    /// `command: examples/punctuation/punctuation.py` reads the file here,
    /// and every config that points a `command:` at it shares the same one.
    /// Edit a file in here and the edit is gone at the next launch; copy it
    /// into `transforms/<name>/` first if you want to keep changes to it.
    /// A file a later version stops shipping is removed from here too, so a
    /// deleted or renamed example does not go on resolving through an
    /// `examples/...` path after the app that shipped it is gone.
    static var installedExamplesDirectory: URL {
        transformsDirectory.appendingPathComponent("examples", isDirectory: true)
    }

    /// Every file under `exampleTransformsDirectory`, as paths relative to
    /// it — `code_identifiers/code_identifiers.py`,
    /// `punctuation/cases.yaml`, and so on.
    ///
    /// Walked rather than named one by one, so a folder that gains a file,
    /// or the tree that gains a folder, is picked up without a list here to
    /// keep in sync with `examples/transforms/`.
    static func exampleTransformFiles() -> [String] {
        filesUnder(exampleTransformsDirectory)
    }

    /// The same walk, over what is actually installed at
    /// `installedExamplesDirectory` — which, right before a refresh, may
    /// still include files an older version shipped and this one does not.
    static func installedExampleFiles() -> [String] {
        filesUnder(installedExamplesDirectory)
    }

    private static func filesUnder(_ root: URL) -> [String] {
        // `enumerator(atPath:)`, not `enumerator(at:)` — it hands back paths
        // already relative to `root`, so there is no absolute prefix to
        // strip. Stripping one was fragile: under `/tmp` or `/var/folders`,
        // the enumerator resolves the ancestor symlink and reports
        // `/private/…`, while `root` does not, and the two disagreed on
        // length.
        guard let enumerator = FileManager.default.enumerator(atPath: root.path)
        else { return [] }
        var files: [String] = []
        for case let relative as String in enumerator {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: root.appendingPathComponent(relative).path, isDirectory: &isDirectory)
            guard exists, !isDirectory.boolValue,
                  !(relative as NSString).lastPathComponent.hasPrefix(".")
            else { continue }
            files.append(relative)
        }
        return files.sorted()
    }

    /// `examples/transforms/` — the one copy of every shipped example, seeded
    /// from here instead of a string in the binary.
    ///
    /// SwiftPM's `resources:` only copies paths inside the target's own
    /// directory: a symlink out to `examples/` gets copied as a symlink, and
    /// it breaks once relocated into the bundle — tried, confirmed broken.
    /// `Bundle.main` after `scripts/build-app.sh` has assembled the .app is
    /// the one place this already works, because that script puts real files
    /// there, the same way it does for the icons.
    ///
    /// Running the raw `swift build`/`swift run` binary has no such bundle —
    /// `isRunningFromBuildDirectory` catches that, and the source tree this
    /// file compiled from is right there to read instead.
    static var exampleTransformsDirectory: URL {
        if !Permissions.isRunningFromBuildDirectory,
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("examples/transforms"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Config.swift -> Sources/ParrotFlow/
            .deletingLastPathComponent()  // -> Sources/
            .deletingLastPathComponent()  // -> repo root
            .appendingPathComponent("examples/transforms", isDirectory: true)
    }

    /// Creates the config file, and refreshes the shipped examples, if they
    /// are not there yet — or, for the examples, whether they are or not.
    ///
    /// **`transforms/examples/` is the app's**, refreshed from
    /// `exampleTransformsDirectory` on every call — every launch, and every
    /// `--seed-config`. That is the point: an improvement to
    /// `code_identifiers.py` reaches every config that points a `command:`
    /// at it, from one copy, instead of a copy per transform that a person
    /// has to notice is stale and re-seed by hand.
    ///
    /// **`transforms/<name>/` is still yours**, and this never writes it. An
    /// install from before this folder existed already has its own
    /// `transforms/punctuation/punctuation.py`, and `command: punctuation.py`
    /// still finds it by the bare-name rule — nothing here moves it, reads
    /// it, or copies over it.
    ///
    /// **A file this version no longer ships is removed from
    /// `transforms/examples/`.** Without that, an example an earlier version
    /// installed but this one dropped or renamed would keep sitting there,
    /// still resolvable through its old `examples/...` path, working when it
    /// should instead be reported as missing.
    static func createIfMissing() throws {
        let fm = FileManager.default
        let source = exampleTransformsDirectory
        let shipped = exampleTransformFiles()
        for relative in shipped {
            let shippedFile = source.appendingPathComponent(relative)
            let destination = installedExamplesDirectory.appendingPathComponent(relative)
            let isNew = !fm.fileExists(atPath: destination.path)
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !isNew { try fm.removeItem(at: destination) }
            try fm.copyItem(at: shippedFile, to: destination)
            if destination.pathExtension == "py" {
                // A shebang does nothing without this.
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
            if isNew { Log.write("config: wrote transforms/examples/\(relative)") }
        }
        let stillShipped = Set(shipped)
        for relative in installedExampleFiles() where !stillShipped.contains(relative) {
            var url = installedExamplesDirectory.appendingPathComponent(relative)
            do {
                try fm.removeItem(at: url)
            } catch {
                // Said out loud, because the whole point of the prune is that a
                // dropped example stops resolving. A failure that logged
                // "removed" would report the opposite of what happened, and the
                // stale `examples/...` path would go on working.
                Log.write("config: could not remove transforms/examples/\(relative):"
                    + " \(error.localizedDescription); it is stale and still resolves")
                continue
            }
            Log.write("config: removed transforms/examples/\(relative) (no longer shipped)")
            // A folder a removed example leaves empty — `retired/` once
            // `retired/retired.py` is gone — is cleaned up too, stopping at
            // the first one that still has something else in it, and never
            // above `installedExamplesDirectory` itself.
            url.deleteLastPathComponent()
            while url.path != installedExamplesDirectory.path,
                  (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                try? fm.removeItem(at: url)
                url.deleteLastPathComponent()
            }
        }
        // The vocabulary, empty but explained. Written so the file exists to
        // be found and read — a person who never dictates a mangled word
        // should still be able to see what the app would learn about them, and
        // an empty file with a header does that better than a missing one.
        if !fm.fileExists(atPath: vocabularyURL.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try defaultVocabularyYAML.write(
                to: vocabularyURL, atomically: true, encoding: .utf8
            )
            Log.write("config: wrote vocabulary.yaml")
        }

        guard !fm.fileExists(atPath: fileURL.path) else { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try defaultYAML.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// What `vocabulary.yaml` says before anything has been learnt.
    ///
    /// Every term is commented out. A vocabulary that arrives with entries in
    /// it is a vocabulary tuned for somebody else's voice.
    static let defaultVocabularyYAML = """
    # ParrotFlow vocabulary — words you say that the recogniser gets wrong.
    #
    # Not only names. A colleague's surname, a drug brand, an internal project,
    # a library, an acronym, or any word you pronounce in a way the model was
    # not trained on. What they have in common is that they sound like
    # something else.
    #
    # DO NOT EDIT UNLESS YOU REALLY KNOW WHAT YOU ARE DOING.
    #
    # This file is learnt while you use the app. Entries arrive when you correct
    # a term. If you want to change something, the safe move is to let the app
    # measure again rather than to pick a number.
    #
    # Two numbers, and they do different jobs. What a spelling makes worth
    # looking at and what the audio can veto are different questions, and one
    # threshold answering both was safe or useful and never both: strict enough
    # to be safe it caught 2 of 20 misheard names, loose enough to catch them
    # "in general" became "in Redcrawl".
    #
    #   offer_below    how far a word's spelling may sit from the term and
    #                  still reach the menu, from 0 to 1, where 1.0 is the term
    #                  spelled exactly. Being offered costs a line the model
    #                  reads; being missed cannot be undone.
    #   decide_above   how hard the audio has to argue against a reading, in
    #                  nats, before it is dropped instead of offered.
    #
    # Per term:
    #
    #   pronunciations  the ways this term actually comes out of the recogniser.
    #                   Each is matched exactly as a rule, and its sound is
    #                   searched for in the audio — which is how a rendering no
    #                   number can reach still finds its term. `seen:` counts
    #                   how often it has turned up, `from:` says who put it
    #                   there: correction, mined or calibration.
    #   floor           `off` — never match this term by its spelling, only by
    #                   its pronunciations. For a term the recogniser writes
    #                   identically to an ordinary word, where no number helps.

    # Matching by sound needs a ~98 MB model, pulled on first use.
    acoustic: false
    offer_below: 0.50
    decide_above: 3.0

    terms: {}
    #  Tasmeen:                     # nothing close in your speech
    #  Praisy:
    #    pronunciations:            # "Prezi" is 0.33 away — no number reaches it
    #      - heard: Prissy
    #        seen: 6
    #        from: mined
    #      - heard: Pressy
    #        seen: 4
    #        from: mined
    #  Claude:
    #    floor: off                 # "cloud" both ways — no number works
    #    pronunciations:
    #      - heard: cloud
    #        from: correction

    """

    /// Reads and decodes the config. Missing keys fall back to the struct defaults.
    static func load() throws -> Config {
        try createIfMissing()
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let config: Config
        // An empty config.yaml is a supported state — it means "defaults for
        // everything" — and it must not take the vocabulary down with it. The
        // two files are independent, and one of them being blank says nothing
        // about the other.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var bare = Config()
            bare.vocabulary = loadVocabulary()
            config = bare
        } else {
            // A relative `command:` is relative to the file that declared it,
            // so a config carries its scripts beside it and a `--pipeline`
            // fixture carries its own.
            var decoded = try YAMLDecoder().decode(
                Config.self, from: text, userInfo: [.configDirectory: directory]
            )
            decoded.vocabulary = loadVocabulary()
            config = decoded
        }
        // Every caller reads the config through here — the app at launch and
        // on every save, and each CLI command once — so this is the one place
        // that has to set it.
        Log.textEnabled = config.logging.text
        return config
    }

    /// `vocabulary.yaml`, or an empty one. A vocabulary that will not parse is
    /// reported and skipped rather than thrown: it is learnt state, and losing
    /// dictation entirely because one line of it is malformed would be the
    /// wrong trade.
    static func loadVocabulary() -> Config.Vocabulary {
        guard let text = try? String(contentsOf: vocabularyURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return Config.Vocabulary() }
        do {
            return try YAMLDecoder().decode(Config.Vocabulary.self, from: text)
        } catch {
            Log.write("vocabulary.yaml could not be read (\(error)); ignoring it")
            return Config.Vocabulary()
        }
    }

    /// `config.example.yaml` — the one copy of the default config's content,
    /// same reasoning as `exampleTransformsDirectory` above: seeded from the
    /// real file instead of a second, hand-synced copy in the binary. It was
    /// a string here for a while, and it drifted — config.example.yaml
    /// gained the vocabulary judge stage and app-scoped transforms that this
    /// string never did, silently, because nothing compared the two beyond a
    /// key-name check that could not see into a pipeline's steps.
    static var configTemplateURL: URL {
        if !Permissions.isRunningFromBuildDirectory,
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("config.example.yaml"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Config.swift -> Sources/ParrotFlow/
            .deletingLastPathComponent()  // -> Sources/
            .deletingLastPathComponent()  // -> repo root
            .appendingPathComponent("config.example.yaml")
    }

    /// What a new install's config.yaml is written with.
    ///
    /// config.example.yaml itself, with the four lines that differ per
    /// variant swapped in. The release build needs no substitution at all —
    /// the file already reads as its own defaults — which is the point: a
    /// release config.yaml and config.example.yaml can now be compared for
    /// equality instead of trusted to have been kept in sync by hand.
    static var defaultYAML: String {
        guard let text = try? String(contentsOf: configTemplateURL, encoding: .utf8) else {
            Log.write("config: could not read \(configTemplateURL.path); writing nothing")
            return ""
        }
        guard AppVariant.isDev else { return text }
        return text
            .replacingOccurrences(
                of: "# ParrotFlow configuration",
                with: "# \(AppVariant.displayName) configuration")
            .replacingOccurrences(
                of: "  key: right_command",
                with: "  key: \(AppVariant.defaultHotkey)")
            .replacingOccurrences(
                of: "  output_dir: ~/Recordings/ParrotFlow",
                with: "  output_dir: \(AppVariant.defaultOutputDir)")
            .replacingOccurrences(
                of: "~/Library/Logs/ParrotFlow.log",
                with: "~/Library/Logs/\(AppVariant.logFileName)")
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
