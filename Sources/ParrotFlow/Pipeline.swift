import Foundation

/// What happens to a transcript between the model finishing and the text
/// landing in your editor.
///
/// It was always a pipeline — exact replacements, then fuzzy ones, then spoken
/// numbers — but the order lived in one function and each step was switched by
/// a boolean of its own. That works until you want a fourth step, or the same
/// three in a different order for a different language, and neither is
/// expressible in a flag.
///
/// So the order becomes data: a list of stages per language, read from the
/// config. This type is the list and the running of it, and nothing else. Every
/// stage is `String -> String` and already had its own validation set before it
/// was a stage; what is new here is only that they are named, ordered and
/// selected from outside the code.
///
/// The language a transcript is in is resolved here, because it is what picks
/// the pipeline. It is *not* handed down to the stages: `numbers` keeps its own
/// resolution, and has to. Its rule is not "read this language" but "try the
/// detected one, then the others, and let a candidate win only on real
/// evidence" — the guard that stops French reading the "cents" in "I have 99
/// cents" as hundreds. Collapsing that to one language here would quietly
/// delete it.
struct Pipeline {

    /// One step. Deliberately not a closure: a stage has to be nameable in a
    /// config file, comparable in a test, and printable in a log, and a
    /// function value is none of those.
    enum Stage: Equatable {
        /// Literal and regex substitutions from `transcription.replacements`.
        case replacements
        /// The same table, used to catch spellings it does not contain.
        /// Meaningless before `replacements` — see `validate`.
        case fuzzy
        /// Spoken numbers as digits, in the resolved language's grammar.
        case numbers

        var name: String {
            switch self {
            case .replacements: return "replacements"
            case .fuzzy: return "fuzzy"
            case .numbers: return "numbers"
            }
        }
    }

    let stages: [Stage]

    /// The pipeline the flags used to describe.
    ///
    /// Phase one keeps them, so that moving three steps behind a type can be
    /// proven to change nothing before anything about the config changes. The
    /// order is the order `Replacements.apply` ran them in, and the reason for
    /// it is still true: both name passes match on words, so a mishearing that
    /// happens to contain a number word — "Ver Sal two" — has to still look
    /// like words while they run. Numbers last, always.
    static func fromFlags(_ config: Config) -> Pipeline {
        var stages: [Stage] = [.replacements]
        if config.transcription.fuzzyMatching { stages.append(.fuzzy) }
        if config.transcription.numbers { stages.append(.numbers) }
        return Pipeline(stages: stages)
    }

    /// Complaints about a pipeline that would run but not do what it looks
    /// like it does. Returned rather than thrown: one bad line should be
    /// reported, not cost you the other stages.
    ///
    /// `fuzzy` before `replacements` is the one that matters. It reads the same
    /// table and depends on the exact pass having already run — by then
    /// "Superbase" is "Supabase", and without that "on Supabase" scores high
    /// enough against "Supabase" to swallow the preceding word.
    func validate() -> [String] {
        var problems: [String] = []
        if let fuzzy = stages.firstIndex(of: .fuzzy) {
            guard let exact = stages.firstIndex(of: .replacements) else {
                problems.append("fuzzy has no replacements before it; it reads that table and will find nothing")
                return problems
            }
            if fuzzy < exact {
                problems.append("fuzzy runs before replacements; it needs the exact pass to have run first")
            }
        }
        return problems
    }

    func run(_ text: String, config: Config) -> String {
        var output = text
        for stage in stages {
            output = apply(stage, to: output, config: config)
        }
        return output
    }

    private func apply(_ stage: Stage, to text: String, config: Config) -> String {
        switch stage {
        case .replacements:
            return Replacements.applyExact(to: text, rules: config.transcription.rules)
        case .fuzzy:
            let targets = config.transcription.replacements.keys.filter { !$0.isEmpty }
            return Replacements.applyFuzzy(to: text, targets: Array(targets))
        case .numbers:
            return Numbers.apply(to: text, languages: config.transcription.languages)
        }
    }
}
