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
    var freeForm: Bool = true

    /// Read from `vocabulary.yaml` beside the config, not from `config.yaml`.
    /// It is maintained by the app rather than by hand — see `Vocabulary`.
    var vocabulary: Vocabulary = Vocabulary()

    /// The directory this config was read from, when the decoder was told.
    ///
    /// A transform resolves its files through `TransformFolder`, which has a
    /// name to hang them on. A `vocabulary:` stage has only a filename, so it
    /// needs the directory itself. Nil for a `Config()` built in code, and
    /// `ConfigStore.directory` is the answer then — see `promptFile`.
    var directory: URL?

    /// A prompt file a stage named, read.
    ///
    /// Relative to the directory the config came from, so a config carries its
    /// prompts beside it the way it already carries its transforms. An absolute
    /// path or one starting `~` is its own answer.
    func promptFile(_ path: String) -> String? {
        let written = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else { return nil }
        let url: URL
        if written.hasPrefix("/") || written.hasPrefix("~") {
            url = URL(fileURLWithPath: (written as NSString).expandingTildeInPath)
        } else {
            url = (directory ?? ConfigStore.directory).appendingPathComponent(written)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case hotkey, audio, feedback, transcription, llm, transforms, prompts, updates
        case freeForm = "free_form"
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

        /// Whether names are matched by sound at all. Off costs nothing; on
        /// pulls a ~98 MB model on first use.
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
        /// The other of the two numbers. Raw on purpose: the rescorer's own
        /// margin carries the vocabulary bonus, and deciding on the boosted
        /// number is how "praise" became `Praisy` (F4). Read by
        /// `Vocabulary.proposalMargin`.
        ///
        /// Generous. `versal` -> `Vercel` is 0.82 against and correct, so the
        /// gate has to sit well clear of an ordinary near-tie. Also shipped
        /// untuned.
        var decideAbove: Float = 3.0

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
                heard: String, seen: Int = 0, from: Source = .legacy,
                note: String? = nil, unreadableFrom: String? = nil
            ) {
                self.heard = heard
                self.seen = seen
                self.from = from
                self.note = note
                self.unreadableFrom = unreadableFrom
            }

            enum CodingKeys: String, CodingKey { case heard, seen, from, note }

            /// Two shapes. The mapping is what the app writes; the bare string
            /// is what a person types when they have nothing else to say:
            ///
            ///     - heard: Versailles
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
            /// True when the list arrived under the old `heard:` key, so
            /// `notices()` can name the key and say what to write instead.
            var wroteHeard = false

            /// Just the renderings, for the callers that only want the
            /// spellings — the exact rules, and the "can anything reach this
            /// term at all" check in `notices()`.
            var heard: [String] { pronunciations.map(\.heard) }

            init(
                offerBelow: Float? = nil, never: Bool = false,
                pronunciations: [Pronunciation] = [], wroteHeard: Bool = false
            ) {
                self.offerBelow = offerBelow
                self.never = never
                self.pronunciations = pronunciations
                self.wroteHeard = wroteHeard
            }

            enum CodingKeys: String, CodingKey { case floor, heard, pronunciations }

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
                    self.init(offerBelow: number, pronunciations: said, wroteHeard: wroteHeard)
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
                        pronunciations: said, wroteHeard: wroteHeard
                    )
                    return
                }
                if let word = (try? c.decodeIfPresent(String.self, forKey: .floor)) ?? nil {
                    self.init(
                        offerBelow: nil, never: word.lowercased() == "off",
                        pronunciations: said, wroteHeard: wroteHeard
                    )
                    return
                }
                self.init(offerBelow: nil, pronunciations: said, wroteHeard: wroteHeard)
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
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let on = try c.decodeIfPresent(Bool.self, forKey: .acoustic) {
                acoustic = on
            }
            // `min_similarity` was the file-level floor that did both jobs. It
            // now does one, so it is read as `offer_below` — the number is
            // kept, the meaning narrows.
            var asked: (key: String, value: Float)?
            if let old = try c.decodeIfPresent(Float.self, forKey: .minSimilarity) {
                asked = ("min_similarity", old)
                legacy.append("`min_similarity: \(old)` is the old name for"
                    + " `offer_below:` — same number, and it now only decides"
                    + " what reaches the menu")
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
            // Nats, and the audio arguing against a reading by a negative
            // amount is the audio agreeing with it. At or below 0 every
            // proposal the decoder does not already prefer is dropped before
            // anyone sees it.
            if let decided = try c.decodeIfPresent(Float.self, forKey: .decideAbove) {
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
                    + " \(floored.joined(separator: ", ")) is legacy — it still"
                    + " sets what is offered for that term, but the setting is"
                    + " `offer_below:` at the top of the file."
                    + " `floor: off` is unaffected and still means never"
                    + " matched by sound")
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

        enum CodingKeys: String, CodingKey {
            case name, description, display, confirm, prompt, content, replace, command
            case tests, returns
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
                body: body, source: entry.source,
                tests: entry.tests
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
        var asTransform: Transform {
            Transform(
                name: name, description: description, display: display,
                confirm: confirm, body: .prompt(content)
            )
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
        ///
        /// `vocabulary:` names a prompt file rather than a transform, for the
        /// same reason `transform:` names a transform: every entry of that kind
        /// needs the second key, and a form that repeats itself is a form
        /// people mistype.
        ///
        ///     - vocabulary: verify_names.md
        ///       when: vocabulary.count > 0
        ///       max_slots: 4
        struct PipelineEntry: Decodable {
            let name: String
            var transform: String?
            var prompt: String?
            var caps: VocabularyJudge.Caps?
            var when: String?
            var unless: String?
            var app: String?
            /// `stage:` and `transform:`/`prompt:`/`vocabulary:` on one entry.
            var namesBoth = false

            private enum CodingKeys: String, CodingKey {
                case stage, transform, prompt, vocabulary, when, unless, app
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
                    var caps = VocabularyJudge.Caps.standard
                    // Each optional and each on its own: a person raising the
                    // menu ceiling should not have to restate the rest.
                    if let slots = try c.decodeIfPresent(Int.self, forKey: .maxSlots) {
                        caps.slots = slots
                    }
                    if let readings = try c.decodeIfPresent(Int.self, forKey: .maxReadings) {
                        caps.readings = readings
                    }
                    if let perSlot = try c.decodeIfPresent(Int.self, forKey: .maxPerSlot) {
                        caps.perSlot = perSlot
                    }
                    if let perTerm = try c.decodeIfPresent(Int.self, forKey: .maxPerTerm) {
                        caps.perTerm = perTerm
                    }
                    self.caps = caps
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
                                contradictoryEntries.append(
                                    entry.transform ?? entry.prompt ?? "transform"
                                )
                                return nil
                            }
                            return Pipeline.Step(
                                stage: stage, transform: entry.transform,
                                prompt: entry.prompt, caps: entry.caps,
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

        enum CodingKeys: String, CodingKey {
            case sound
            case overlay
            case correctOffer = "correct_offer"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            if let sound = try c.decodeIfPresent(Bool.self, forKey: .sound) { self.sound = sound }
            if let overlay = try c.decodeIfPresent(Bool.self, forKey: .overlay) { self.overlay = overlay }
            if let offer = try c.decodeIfPresent(Bool.self, forKey: .correctOffer) {
                self.correctOffer = offer
            }
        }
    }

    init() {}

    /// Hand-rolled so a partial config.yaml is valid: anything you leave out
    /// keeps its default instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        directory = decoder.userInfo[.configDirectory] as? URL
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
        let assembled = Self.assembled(entries)
        transforms = assembled.kept
        unreadableTransforms = assembled.unreadable
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
        // Numbers `vocabulary.yaml` asked for and did not get. Refused where
        // they were read, so what runs is the default; said here, because a
        // setting that does nothing is exactly what this list is for.
        found += vocabulary.refused.map { "vocabulary: \($0)" }
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

        // The name judge is a stage now. A pipeline that still names it as a
        // transform keeps working — a `command:` transform is a supported
        // escape hatch and this does not rewrite anybody's config — but it is
        // running the old hand-off, where the positions are re-derived from
        // occurrence counts that no longer hold once a stage edits the text
        // (F10). Said once, however many languages spell it.
        let legacyJudge = transcription.languages.contains { language in
            Pipeline.resolved(config: self, language: language).steps.contains {
                $0.stage == .transform
                    && $0.transform?.caseInsensitiveCompare("verify_names") == .orderedSame
            }
        }
        if legacyJudge {
            said.append("pipelines: `- transform: verify_names` is the old name judge."
                + " The app does this itself now — write `- vocabulary: verify_names.md`,"
                + " with the prompt file beside config.yaml")
        }

        // The vocabulary is learnt rather than written, so it is the part of
        // the configuration nobody remembers the contents of. Printed in full.
        let rules = vocabularyRules.count
        if !vocabulary.terms.isEmpty {
            let byEar = vocabularyTerms
            said.append("vocabulary: \(vocabulary.terms.count) terms in"
                + " \(ConfigStore.vocabularyURL.lastPathComponent),"
                + " \(byEar.count) matched by sound, \(rules) by rule")
            // Spelled out rather than printed as `offer_below 0.5`. The key
            // names the job; only a sentence says which way the number points.
            if vocabulary.acoustic, !byEar.isEmpty {
                said.append("vocabulary: offered at similarity"
                    + " \(vocabulary.offerBelow) and up, dropped when the audio"
                    + " argues against it by more than \(vocabulary.decideAbove)"
                    + " nats — "
                    + byEar.map { $0.offerBelow == vocabulary.offerBelow
                        ? $0.text : "\($0.text) \($0.offerBelow)" }
                        .joined(separator: ", "))
            }
            if !vocabulary.acoustic, !byEar.isEmpty {
                said.append("vocabulary: `acoustic: false`, so \(byEar.count) names"
                    + " are only matched by their pronunciation rules")
            }
            // How many renderings reach the spotter, and how many are rules
            // only. The second number is the one nobody expects: a rendering
            // travels into the audio search under its term's name, so a term
            // the pass does not search for has nothing to report it as.
            let heard = vocabularyPronunciations
            let mute = rules - heard.count
            if vocabulary.acoustic, rules > 0 {
                var both: [String] = []
                if !heard.isEmpty {
                    both.append("\(heard.count) pronunciation(s) searched for by sound"
                        + " as well as matched exactly")
                }
                if mute > 0 {
                    both.append("\(mute) matched exactly only — their term is not"
                        + " searched for by sound, so nothing could report them")
                }
                said.append("vocabulary: " + both.joined(separator: ", "))
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

    /// The folder the `code_identifiers` transform owns.
    static var codeIdentifiersFolder: URL {
        transformsDirectory.appendingPathComponent("code_identifiers", isDirectory: true)
    }

    /// Where the `code_identifiers` transform's program lives — in its folder,
    /// which is what makes `command: code_identifiers.py` resolve.
    static var codeIdentifiersURL: URL {
        codeIdentifiersFolder.appendingPathComponent("code_identifiers.py")
    }

    /// Creates the config file, and the one transform it ships with, if they
    /// are not there yet.
    ///
    /// A folder rather than two loose files, because that is the layout the
    /// app reads and a shipped example that does not demonstrate it teaches
    /// the wrong thing. The case set goes in with the script: a transform that
    /// arrives with its own set is the whole argument of docs/authoring.md
    /// made concrete, and `--eval code_identifiers` finds it by convention.
    ///
    /// The script is written rather than bundled because this app has no
    /// resources — `defaultYAML` is a string in the binary for the same reason
    /// — and because a script you can open and edit beside your config is the
    /// point of it. Nothing here is ever overwritten: once it exists it is
    /// yours, and an update that reverted your stop lists would be the app
    /// taking back something it gave you.
    static func createIfMissing() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: codeIdentifiersURL.path) {
            try fm.createDirectory(at: codeIdentifiersFolder, withIntermediateDirectories: true)
            try defaultCodeIdentifiersScript.write(
                to: codeIdentifiersURL, atomically: true, encoding: .utf8
            )
            // A shebang does nothing without this.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codeIdentifiersURL.path)
            Log.write("config: wrote transforms/code_identifiers/code_identifiers.py")
        }
        let cases = codeIdentifiersFolder.appendingPathComponent("cases.yaml")
        if !fm.fileExists(atPath: cases.path) {
            try fm.createDirectory(at: codeIdentifiersFolder, withIntermediateDirectories: true)
            try defaultCodeIdentifiersCases.write(to: cases, atomically: true, encoding: .utf8)
            Log.write("config: wrote transforms/code_identifiers/cases.yaml")
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

    /// The shipped copy of examples/transforms/code_identifiers/cases.yaml.
    ///
    /// Written into the folder beside the script, so the one transform this
    /// app ships arrives with the thing every other rewrite in its repository
    /// has and no user ever got: a set to score it against. `--eval
    /// code_identifiers` runs it.
    ///
    /// Two copies of one file again, and kept honest the same way —
    /// scripts/check-seeded-transform.sh fails when they differ. The one in
    /// examples/ is the one to edit.
    static let defaultCodeIdentifiersCases = #"""
# Validation set for spoken identifiers — a transform that turns a name said
# out loud into the identifier a language would spell it as. Run with
# scripts/validate-code-identifiers.py.
#
# The question it exists to answer: can one prompt, on a small local model, do
# this on its own? If it can, the whole feature is a `transforms:` entry and a
# pipeline line in config.yaml, and nothing enters the app at all. If it cannot,
# the fallback is a prompt that only *marks* the names and a `replace:` table
# that cases them — which needs a case operator the substitution engine does
# not have. This set is what decides between the two, and it judges both the
# same way.
#
# Two halves, and the second is the important one.
#
#   change  a name is introduced as a function, variable, class or constant.
#           The right answer is that name in the language's convention, with
#           every other word of the transcript untouched.
#   keep    nothing is being named. The right answer is the transcript, byte
#           for byte.
#
# `keep` is nearly half the set on purpose. This transform runs on *every*
# transcript in the pipeline it is added to, so the failure it invites is not
# getting a name wrong — it is quietly rewriting a sentence that needed
# nothing. A model that scores well on `change` and poorly on `keep` has made
# the feature unusable, because you would have to proof-read every dictation.
#
# The contract, which is the boundary the set argues about on purpose: convert
# only what the speaker introduces as a name — "a function called X", "une
# variable qui s'appelle X", "the class X". A noun phrase that merely describes
# something ("the retry count is too high") is prose. Both sides are here.
#
# The convention comes from the language if one was said, and is camelCase when
# none was:
#
#   python, rust, ruby, elixir   snake_case
#   javascript, typescript, java, go, swift, php   camelCase
#   a class or a type            PascalCase
#   a constant                   SCREAMING_SNAKE_CASE
#   nothing said                 camelCase
#
# Inputs are dictated, so they are lowercase and unpunctuated where a speaker
# would be, and they mix French and English the way this app is used.

cases:
  # ---- A language was said ------------------------------------------------
  - name: python function
    kind: change
    category: language-said
    input: add a python function called max retries
    expect: add a python function called max_retries

  - name: python variable, three words
    kind: change
    category: language-said
    input: in python a variable called user profile name
    expect: in python a variable called user_profile_name

  - name: rust variable
    kind: change
    category: language-said
    input: rust variable called retry count
    expect: rust variable called retry_count

  - name: typescript function
    kind: change
    category: language-said
    input: a typescript function named get user profile
    expect: a typescript function named getUserProfile

  - name: javascript variable
    kind: change
    category: language-said
    input: javascript variable called is logged in
    expect: javascript variable called isLoggedIn

  - name: java function, five words
    kind: change
    category: language-said
    input: a java method called build request from config
    expect: a java method called buildRequestFromConfig

  - name: go function
    kind: change
    category: language-said
    input: a go function called parse config file
    expect: a go function called parseConfigFile

  - name: swift function
    kind: change
    category: language-said
    input: swift function named reload dictation model
    expect: swift function named reloadDictationModel

  # ---- A class or a type takes PascalCase whatever the language ------------
  - name: python class
    kind: change
    category: class
    input: a python class called user service
    expect: a python class called UserService

  - name: typescript type
    kind: change
    category: class
    input: a typescript type called retry policy
    expect: a typescript type called RetryPolicy

  - name: class, no language
    kind: change
    category: class
    input: create a class called audio recorder
    expect: create a class called AudioRecorder

  # ---- A constant takes screaming snake ------------------------------------
  - name: python constant
    kind: change
    category: constant
    input: a python constant called max retry count
    expect: a python constant called MAX_RETRY_COUNT

  - name: constant, no language
    kind: change
    category: constant
    input: a constant called default timeout seconds
    expect: a constant called DEFAULT_TIMEOUT_SECONDS

  # ---- No language said: camelCase ----------------------------------------
  - name: bare function
    kind: change
    category: default-camel
    input: a function called user profile name
    expect: a function called userProfileName

  - name: bare variable
    kind: change
    category: default-camel
    input: a variable named retry count
    expect: a variable named retryCount

  - name: bare function, two words
    kind: change
    category: default-camel
    input: write a function called send email
    expect: write a function called sendEmail

  # ---- French ---------------------------------------------------------------
  - name: fonction python
    kind: change
    category: french
    input: une fonction python qui s'appelle calculer le total
    expect: une fonction python qui s'appelle calculer_le_total

  - name: variable typescript
    kind: change
    category: french
    input: en typescript une variable qui s'appelle nom utilisateur
    expect: en typescript une variable qui s'appelle nomUtilisateur

  - name: fonction sans langage
    kind: change
    category: french
    input: crée une fonction qui s'appelle envoyer le rapport
    expect: crée une fonction qui s'appelle envoyerLeRapport

  - name: classe française
    kind: change
    category: french
    input: une classe qui s'appelle lecteur audio
    expect: une classe qui s'appelle LecteurAudio

  # ---- Where does the name end --------------------------------------------
  # The sentence continues after the name, and everything after it is prose.
  # This is the same span problem the spelling correction has, and it is where
  # a model that is doing the job by feel will over-reach.
  - name: name then a relative clause
    kind: change
    category: boundary
    input: add a python function called max retries that returns the count
    expect: add a python function called max_retries that returns the count

  - name: name then a purpose
    kind: change
    category: boundary
    input: a typescript function named get user profile for the settings page
    expect: a typescript function named getUserProfile for the settings page

  - name: name in the middle
    kind: change
    category: boundary
    input: the function called reload config should run on save
    expect: the function called reloadConfig should run on save

  - name: two names in one sentence
    kind: change
    category: boundary
    input: a python function called read config and a variable called config path
    expect: a python function called read_config and a variable called config_path

  # ---- keep: ordinary prose -------------------------------------------------
  - name: plain sentence
    kind: keep
    category: prose
    input: we should ship it on friday if the tests are green

  - name: meeting note
    kind: keep
    category: prose
    input: i told them we would look at it again after the release

  - name: prose with a number
    kind: keep
    category: prose
    input: it took about forty minutes and we still did not finish

  - name: email sentence
    kind: keep
    category: prose
    input: thanks for the quick turnaround on this one really appreciated

  - name: phrase française
    kind: keep
    category: prose
    input: on en reparle demain matin avant la réunion

  # ---- keep: the words are there, the naming is not -------------------------
  # "function", "variable", a language name — every trigger word this transform
  # keys on, in a sentence that names nothing. These are the ones that decide
  # whether it can be left on.
  - name: function as an English word
    kind: keep
    category: near-miss
    input: that function of the business was outsourced years ago

  - name: python as a topic
    kind: keep
    category: near-miss
    input: we talked about python packaging for most of the afternoon

  - name: describing a variable, not naming one
    kind: keep
    category: near-miss
    input: the retry count is too high and it hammers the api

  - name: a person called Max
    kind: keep
    category: near-miss
    input: i called max yesterday and he had not seen the ticket

  - name: variable en français, sans nom
    kind: keep
    category: near-miss
    input: la variable dépend de la charge du serveur ce jour là

  - name: a class in the school sense
    kind: keep
    category: near-miss
    input: she has a class at nine so we moved the standup

  # ---- keep: already an identifier -----------------------------------------
  # Nothing to do, and the invitation to re-case something that is already
  # right — or to "fix" a convention the speaker meant.
  - name: already camel
    kind: keep
    category: already-done
    input: call getUserProfile before the render happens

  - name: already snake
    kind: keep
    category: already-done
    input: max_retries is set to three in the config file

  - name: deliberately mixed conventions
    kind: keep
    category: already-done
    input: the python side uses max_retries and the client sends maxRetries

  - name: a dotted path
    kind: keep
    category: already-done
    input: read config.port from user.name before anything else

  # ---- keep: it is a question or an aside ----------------------------------
  - name: a question about code
    kind: keep
    category: near-miss
    input: what does the parser do when the header is missing

  - name: an aside about naming
    kind: keep
    category: near-miss
    input: honestly the naming in that module has never made any sense

  # ---- Held out while the code-only control was being tuned ----------------
  #
  # The control reached 100% on everything above, which is worth nothing on its
  # own: the stop list and the "a kind word must precede the naming phrase"
  # rule were both written *because* of failures in that half. These fifteen
  # were written afterwards and used to tune nothing. They cost the control one
  # case — the passive "called by the scheduler", which every cheap rule fires
  # on — and the model five.
  #
  # They are part of the set now, so the next change needs new ones.
  - name: ruby method
    kind: change
    category: language-said
    input: a ruby method called fetch remote config
    expect: a ruby method called fetch_remote_config

  - name: go variable
    kind: change
    category: language-said
    input: declare a go variable named http client timeout
    expect: declare a go variable named httpClientTimeout

  - name: elixir function containing to
    kind: change
    category: boundary
    input: an elixir function called broadcast message to room
    expect: an elixir function called broadcast_message_to_room

  - name: php variable
    kind: change
    category: language-said
    input: a php variable called current user id
    expect: a php variable called currentUserId

  - name: constante française
    kind: change
    category: french
    input: une constante python qui s'appelle taille maximale
    expect: une constante python qui s'appelle TAILLE_MAXIMALE

  - name: struct
    kind: change
    category: class
    input: a struct called connection pool
    expect: a struct called ConnectionPool

  - name: typescript interface
    kind: change
    category: class
    input: a typescript interface named payment method
    expect: a typescript interface named PaymentMethod

  - name: name then modal
    kind: change
    category: boundary
    input: the variable called last seen at should be nullable
    expect: the variable called lastSeenAt should be nullable

  - name: rust constant
    kind: change
    category: constant
    input: add a rust constant called default buffer size
    expect: add a rust constant called DEFAULT_BUFFER_SIZE

  # "called" that introduces nothing — the passive. A kind word sits right in
  # front of it, so every cheap rule fires here.
  - name: called by, not called X
    kind: keep
    category: near-miss
    input: a python function called by the scheduler every hour

  - name: called it useless
    kind: keep
    category: near-miss
    input: he called the function useless in the review yesterday

  - name: class in the school sense again
    kind: keep
    category: near-miss
    input: the class was late so we started the demo without her

  - name: named a cat
    kind: keep
    category: near-miss
    input: i named my cat after a rust crate honestly

  - name: type as a verb
    kind: keep
    category: near-miss
    input: we should type the config properly before shipping it

  - name: variable qui change
    kind: keep
    category: near-miss
    input: on a une variable qui change tout le temps sur ce serveur

  # ---- Held out a second time: a kind word and a naming word, in prose ----
  #
  # Written to break the script rather than to flatter it, and they did: 2/8
  # before a length cap, because "the class called intro to python starts at
  # nine tomorrow" has every marker a naming has. Nobody dictates a five-word
  # identifier, and declining beyond four is what tells them apart. The
  # remaining one — "a method called cognitive behavioural therapy" — is three
  # plausible words and no surface rule separates it from a name.
  - name: a class with a name, in the school sense
    kind: keep
    input: the class called intro to python starts at nine tomorrow
  - name: a method in the medical sense
    kind: keep
    input: there is a method called cognitive behavioural therapy for that
  - name: naming after someone
    kind: keep
    input: he named the variable after his cat which i think is unwise
  - name: a function in the event sense
    kind: keep
    input: the function called the annual review is on friday afternoon
  - name: a type of person
    kind: keep
    input: she is the type called on whenever something breaks at night
  - name: a constant complaint
    kind: keep
    input: the constant called for by the spec is not what we shipped
  - name: une classe au sens scolaire
    kind: keep
    input: la classe qui s'appelle initiation au python commence à neuf heures
  - name: a variable in the statistical sense
    kind: keep
    input: the variable called into question was the sample size all along
  # And two that must still work, so a fix cannot just switch everything off.

  # ---- No marker at all: the only job left for a model ---------------------
  #
  # A name given without "called": "call it X", "rename it to X", "a getter for
  # X". The script declines every one of these by construction, and they are
  # the cases that decide whether a prompt earns its second here.
  - name: call it, no kind word
    kind: change
    input: call it max retries in python
    expect: call it max_retries in python
  - name: a helper, said as prose
    kind: change
    input: write a python helper that reads the config file and call it load config
    expect: write a python helper that reads the config file and call it load_config
  - name: naming by apposition
    kind: change
    input: i need a typescript getter for the user profile name
    expect: i need a typescript getter for the userProfileName
  - name: rename
    kind: change
    input: rename the python variable to retry count
    expect: rename the python variable to retry_count
  - name: French, no kind word
    kind: change
    input: appelle ça nombre de tentatives en python
    expect: appelle ça nombre_de_tentatives en python
  # The hard keep the script still fails, so a prompt gets a chance at it too.
  - name: a method in the medical sense
    kind: keep
    input: there is a method called cognitive behavioural therapy for that

  # ---- Languages the old pattern did not know -----------------------------
  #
  # `python|rust|ruby|elixir` meant snake_case and everything else meant camel,
  # so each of these was silently wrong. Held out while BY_LANGUAGE was written
  # to replace that pattern: the rules scored 1/5 before it and 5/5 after, with
  # no model involved. Asking the model for the language is what made the table
  # worth having — a pattern has to be edited to learn a language, a table has
  # to be added to.

  - name: zig
    kind: change
    category: language-said
    input: a zig function called read config file
    expect: a zig function called read_config_file

  - name: c sharp
    kind: change
    category: language-said
    input: a c# method called build request
    expect: a c# method called BuildRequest

  - name: kotlin
    kind: change
    category: language-said
    input: a kotlin function called retry count
    expect: a kotlin function called retryCount

  - name: julia
    kind: change
    category: language-said
    input: a julia function called solve system
    expect: a julia function called solve_system

  - name: erlang
    kind: change
    category: language-said
    input: an erlang function called handle call
    expect: an erlang function called handle_call
"""#

    /// The shipped copy of examples/transforms/code_identifiers/code_identifiers.py.
    ///
    /// Two copies of one file, which is a thing this repo has been bitten by
    /// twice — so scripts/check-seeded-transform.sh fails when they differ. The
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

A copy of this folder — this file and cases.yaml beside it — is written to
~/.config/parrotflow/transforms/code_identifiers/ on first launch and never
overwritten afterwards, and the step above is in the default pipeline. This
one, in examples/, is the copy you read and edit; see
scripts/check-seeded-transform.sh, which keeps the two equal.

Why a script and not a prompt: measured. On examples/transforms/code_identifiers/cases.yaml, 56
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
import os
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


def convert(text, converted=None):
    """The rewrite. `converted`, if given, is appended one entry per name taken.

    An out-parameter rather than a second return value because
    `scripts/validate-code-identifiers.py` calls this as `shipped.convert` and
    compares its result to a string — a tuple would have changed what the
    scoreboard measures in order to add a number nothing there reads.
    """
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
            if converted is not None:
                converted.append(span)
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


def place(reply, text, converted=None):
    """The extraction applied — the deterministic half, sharing `cased` and
    `style_for` with the rules above so there is one algorithm and not two.

    `converted` is appended one entry per name taken, exactly as `convert` does
    — the two paths produce the same kind of rewrite and have to report it the
    same way. A model conversion that did not count would publish `count: 0` on
    a sentence this stage had just rewritten, and the stage below, told to stand
    down when the count is zero, would run anyway.
    """
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
        if converted is not None:
            converted.append(span)
    return out


if __name__ == "__main__":
    model = None
    if "--model" in sys.argv:
        index = sys.argv.index("--model")
        model = sys.argv[index + 1] if len(sys.argv) > index + 1 else None

    # Two protocols, and which one is in force is decided by the config rather
    # than by anything here: ParrotFlow sets PARROTFLOW_PROTOCOL=json when the
    # transform declares `returns: json`, and leaves it unset otherwise.
    #
    # Reading the environment rather than taking a flag keeps `returns:` the
    # single declaration — a flag in the `command:` line would say the same
    # thing one line lower and could disagree with it. It also keeps this
    # runnable by hand: `echo "a python function called max retries" |
    # ./code_identifiers.py` takes the plain path, which is what every harness
    # in scripts/ does and what anybody debugging one will type.
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"

    raw = sys.stdin.read()
    if structured:
        text = json.loads(raw)["text"]
    else:
        text = raw.rstrip("\n")

    converted = []
    out = convert(text, converted)
    asked = False
    # The model is asked only about what the rules declined. On a sentence with
    # a marker in it — the common case — nothing is paid at all.
    #
    # `converted` is passed on rather than reset: the branch is only reached
    # when the rules took nothing, so it is empty here — but threading it keeps
    # `count` meaning "names this stage converted" regardless of which half did
    # it, which is the only reading a condition below can rely on.
    if model and out == text:
        asked = True
        out = place(ask(model, text), text, converted)

    if not structured:
        sys.stdout.write(out)
        raise SystemExit(0)

    # `count` is what a later stage wants: `dotted` should stand down when this
    # already took the sentence, and until now the only way to ask was to
    # re-derive the judgement from the words. `asked` is for the log rather than
    # for a condition — it is the difference between a stage that cost nothing
    # and one that cost a second, and it was previously invisible.
    sys.stdout.write(json.dumps({
        "text": out,
        "vars": {"count": len(converted), "asked_model": asked},
    }))
"""#

    /// Reads and decodes the config. Missing keys fall back to the struct defaults.
    static func load() throws -> Config {
        try createIfMissing()
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        // An empty config.yaml is a supported state — it means "defaults for
        // everything" — and it must not take the vocabulary down with it. The
        // two files are independent, and one of them being blank says nothing
        // about the other.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var bare = Config()
            bare.vocabulary = loadVocabulary()
            return bare
        }
        // A relative `command:` is relative to the file that declared it, so a
        // config carries its scripts beside it and a `--pipeline` fixture
        // carries its own.
        var config = try YAMLDecoder().decode(
            Config.self, from: text, userInfo: [.configDirectory: directory]
        )
        config.vocabulary = loadVocabulary()
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

    /// Computed rather than a constant because the dev build seeds a different
    /// hotkey and recordings directory — see `AppVariant`.
    static var defaultYAML: String {
        """
    # \(AppVariant.displayName) configuration
    # Edit and save — changes are picked up automatically. Delete any line to
    # get its default back. `--check-config` says what the file adds up to.

    hotkey:
      # A bare modifier — right_option, left_option, right_command,
      # left_command, right_control, left_control, right_shift, left_shift, fn
      # — or a character key (a-z, 0-9, f1-f20, space, return, arrows,
      # punctuation), which needs `modifiers` below.
      key: \(AppVariant.defaultHotkey)

      # Any of: command, control, option, shift.
      modifiers: []

      # push_to_talk records while the key is held; toggle taps on and off.
      # A bare modifier wants push_to_talk, or typing an accented character
      # with it would start recording.
      mode: push_to_talk

      # Keep the mic open this long after you let go, so the last syllable is
      # not cut off. push_to_talk only. 0 turns it off.
      release_tail_seconds: 0.3

    audio:
      # Where the recordings and trace.jsonl go.
      output_dir: \(AppVariant.defaultOutputDir)

      # Skip clips with no speech in them, so a stray keypress does not decode
      # room tone into a sentence.
      speech_gate: true

    feedback:
      sound: true     # a click when recording starts and stops
      overlay: true   # the floating pill while you speak
      # After the words land the pill offers to correct them for 3s. Tap the
      # dictation hotkey — press and let go — to open the correction panel over
      # what was just written. Holding it still starts the next dictation.
      correct_offer: true

    transcription:
      # paste     -> typed into the app you're in (needs Accessibility)
      # clipboard -> copied, you press Cmd-V
      insert_mode: paste

      # Say one of these and what follows is an instruction: "hey parrot, make
      # that a bullet list". One of them mid-sentence turns the rest into an
      # instruction about the words before it. An empty list turns this off.
      activation_phrases: [hey parrot, by the way parrot]

      # Terminals only: they cannot be edited in place, so the input line is
      # cleared and retyped corrected. Everywhere else ignores this.
      rewrite_line: true

      # Languages you dictate in, most spoken first. Supported: en, fr.
      # One entry means no detection runs. Name only what you actually speak.
      languages: [en]

      # What a finished transcript runs through, in order. A stage runs only if
      # it is listed here.
      #
      #   replacements  the table below
      #   fuzzy         the same table against words the spell checker does not
      #                 know. Needs replacements before it
      #   numbers       "two hundred forty-three" -> 243, ordinals, decimals
      #
      # A transform can be a stage too, and any stage takes a condition — on the
      # text with `when:` / `unless:`, or on the app with `app:`. A key per
      # language wins over `default`. See docs/pipelines.md.
      pipelines:
        default:
          - replacements
          - fuzzy
          - numbers
          # "read user dot name" -> read user.name, where you write code-ish text.
          - transform: dotted
            app: /term|ghostty|warp|kitty|alacritty|hyper|slack|discord/
          # "a python function called max retries" -> ...called max_retries. The
          # script is written to transforms/code_identifiers/ on first launch, with
          # its own case set beside it, and both are yours to edit.
          - transform: code_identifiers
            app: /term|ghostty|warp|kitty|alacritty|hyper|code|cursor|zed|xcode|jetbrains|idea|pycharm|webstorm/
            when: /\\b(?:function|method|variable|class|constant|type|struct|interface|enum|fonction|méthode|classe|constante)\\b/

      # The spelling you want, and the ways it comes out wrong. Whole words,
      # case-insensitive. A source in /slashes/ is a regular expression, and
      # then the target is a template where $1 writes back what it captured. An
      # empty target deletes, which is how filler words go.
      #
      #   Supabase: [super base, superbees]
      #   "": ['/[,]?\\s*\\b(?:u+m+|u+h+|erm+|hmm+)\\b[,]?/']
      replacements: {}



    # The local Ollama model behind spoken commands. Without it dictation still
    # works and every `prompt:` transform below stops.
    llm:
      enabled: true
      model: gemma4:e4b
      endpoint: http://localhost:11434
      # Pin the model in RAM. Ollama otherwise drops it after five minutes and
      # the next command waits 7-10s for the reload.
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
      # Checking whether a newer ParrotFlow exists: one call a day to GitHub's
      # release API, nothing about you or what you dictate.
      #
      #   -1  never ask     0  offer it the day it is published
      #    7  only offer a release that has existed for a week
      #
      # The wait is the point: a bad release is one that gets noticed and
      # pulled, and a week of distance means your Mac never saw it.
      after_days: 7

    # What the activation phrase can reach, and what a pipeline can name.
    #
    #     "hey parrot, make that a bullet list"
    #
    # A description is not a comment — it is what the router matches your words
    # against, so write it the way you would say it.
    #
    # One of three bodies. `prompt:` asks the local model and costs about a
    # second; `replace:` is a substitution table and costs nothing; `command:`
    # runs a program of yours — transcript on stdin, rewrite on stdout — and
    # costs a process start. A `command:` is the one thing in this file that
    # runs code, and --check-config names every one out loud.
    #
    # A transform owns transforms/<name>/ beside this file: its script or its
    # prompt, and the case set `--eval <name>` scores it against. A long body
    # can live there instead of here — `prompt: { path: slack.md }`.
    #
    # `display:` is what the menu bar says while it runs. Results are shown
    # before they replace your selection; `confirm: false` skips that.
    # See docs/pipelines.md.
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

      # Scoped to one kind of window each by the pipeline above. `grammar` mends
      # a sentence; these two also lay one out, which is the part no substitution
      # can express. Both are told twice not to write anything: a model handed a
      # dictated email will gladly return a better one in its own voice.
      - name: email
        description: lay dictated text out as an email
        display: Laying out the email
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

          The email ends on the last thing the speaker said. If that last
          thing is a name, it is a signature: a blank line, then the name on
          its own line, and a closing word said just before it — thanks,
          merci — on the line above. If it is anything else — a question, a
          goodbye, a sentence — that is the last line, and there is nothing
          under it. The only name that can appear is one that was spoken; an
          unspoken one has no stand-in, in brackets or otherwise.

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
        display: Tidying for chat
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

      # Said out loud — "hey parrot, use Slack mentions" — and deliberately in
      # no pipeline. A message that names someone is not a message that pings
      # them, and nothing in a transcript tells the two apart. So this is the
      # one you ask for.
      #
      # `confirm` covers one of the two ways of asking. With text selected the
      # result is shown first; mid-sentence there is no preview whatever
      # `confirm` says. Either way what lands is text in your composer, and
      # ParrotFlow sends nothing.
      #
      # It was two `replace:` tables for a while — a table cannot invent a
      # handle, where this prompt's first draft answered "Sofia already looked
      # at it" with "@priya already looked at it". They came back out because a
      # table has to be triggered from inside the sentence, and "mention" is a
      # word English already uses: "I should mention here that the deadline
      # changed" became "I should @here that the deadline changed". A pipeline
      # stage has no preview, so a false positive there is a message already
      # sent. Asking out loud fires when you ask and never otherwise. The whole
      # excursion is written up in config.example.yaml.
      #
      # Put your own people in the list.
      - name: slack_mentions
        description: turn people's names into Slack mentions
        display: Adding mentions
        prompt: |
          Return the text word for word, with one kind of change and no
          other: a name that appears in this list becomes its handle.

            Marie   -> @marie.dupont
            Thomas  -> @tleroy
            Priya   -> @priya

          Every occurrence, including where the message is about that person
          rather than to them.

          A name that is not in the list is left exactly as it was. Sofia
          stays Sofia. Never give a name a handle that belongs to someone
          else, and never invent one.

          Two group mentions are a judgement rather than a lookup. "everyone
          here", "whoever is around" -> @here, which pings the people who are
          online. "the whole channel", "everyone", "all of them" -> @channel,
          which pings the ones who are away too. Only where the text means
          the people: "the file is here" is a place, and stays.

          A mention replaces the words that name the person or the group, and
          not one word more: "heads up to the whole channel" comes back as
          "heads up to @channel".

          Nothing is ever deleted. Every other word, the order and the
          punctuation come back as they went in.

          Return only the text.

      # The two tables the pipeline above names. Same pattern, different output —
      # that is the whole reason a table has a name.
      #
      # The pattern reads "a word, then dot or point, then a word", then refuses
      # it when either side is a word code does not use there — without that,
      # "voilà le point sur les tests" loses its middle. Score it with
      # scripts/check-dotted.sh, which reads the pattern out of this file.
      - name: dotted
        description: spoken dotted paths as code
        replace:
          '$1.': ['/\\b(?!(?:le|la|les|l|un|une|des|du|de|d|ce|cet|cette|ces|mon|ma|mes|ton|ta|tes|son|sa|ses|notre|nos|votre|vos|leur|leurs|au|aux|à|quel|quelle|chaque|autre|même|premier|première|deuxième|dernier|dernière|seul|seule|bon|bonne|mauvais|certain|tel|telle|quelque|the|a|an)\\b)(\\w+) (?:dot|point) (?!(?:de|du|des|d|le|la|les|l|un|une|sur|dans|en|et|ou|que|qui|où|à|au|aux|pour|par|avec|sans|est|sont|était|sera|me|te|se|ne|n|c|il|elle|je|tu|nous|vous|ils|elles|ce|plus|moins|très|mais|donc|car|si|comme|final|finale|barre|virgule|commun|commune|faible|faibles|fort|forts|mort|culminant|névralgique|chaud|sensible|positif|négatif|clé|focal|nommé|com|net|org|matrix|product|notation|plot)\\b)(?=\\w)/']

      - name: backticks
        description: wrap dotted paths in backticks, for chat
        replace:
          '`$1`': ['/\\b([A-Za-z_]\\w*(?:\\.[A-Za-z_]\\w*)+)/']

      # A program rather than a table, because casing words is not something a
      # substitution can express. Written to transforms/code_identifiers/ on
      # first launch and yours to edit — the stop lists in it decide where a name
      # ends, which is a judgement about how you speak.
      - name: code_identifiers
        description: spoken names as identifiers
        display: Formatting identifiers
        command: code_identifiers.py
        # Add `--model gemma4:e4b` to have a model handle the namings the rules
        # cannot see. It takes the sentences that should change from 88% to 100%
        # and the ones that must not from 94% to 84%, so it is off by default.
        # Raise timeout_seconds with it — Ollama takes 7-10s cold.
        # timeout_seconds: 12

    # Do what was asked even when no transform above matches:
    # "hey parrot, sort that list alphabetically". A remark that was never an
    # instruction is still refused, and you see every result first.
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
