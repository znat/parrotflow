import Foundation

/// The part of reading a spoken number that changes with the language.
///
/// `Numbers` holds the machinery — where a number begins and ends, which
/// adjacent groups are a year, when a word stays a word — and none of that is
/// English. What is English is about a hundred lines: the vocabulary, how a
/// tens word combines with what follows it, whether a bare scale word counts as
/// one of itself, and how a decimal point and an ordinal are written. Those
/// live here, one value per language.
///
/// The split was drawn by reading the file rather than guessing at it, and the
/// test is whether a new language can be added without reopening `Numbers`.
/// Spanish, Italian and Portuguese can: their numerals are separated words with
/// an additive tens rule, and their fused forms (`veintiuno`, `ventuno`) are a
/// dozen extra dictionary entries, which is data. German cannot, and no setting
/// here will make it: `einundzwanzig` is one token in reversed order, which
/// breaks tokenising before a grammar is ever consulted.
struct NumberGrammar {

    /// How a tens word combines with the words after it.
    enum TwoDigitRule {
        /// English, Spanish, Italian: a tens word takes at most one unit.
        /// "forty three" is 43 and nothing else follows.
        case additive
        /// French: `soixante-dix` is 60 + 10, `quatre-vingts` is 4 × 20, and
        /// `quatre-vingt-dix` is both at once. The vigesimal leftovers are the
        /// reason this enum exists rather than a flag.
        case vigesimal
    }

    let units: [String: Int]
    let teens: [String: Int]
    let tens: [String: Int]
    let scales: [String: Int]
    let hundred: Set<String>

    let ordinalUnits: [String: Int]
    let ordinalTeens: [String: Int]
    let ordinalTens: [String: Int]
    let ordinalScales: [String: Int]
    let ordinalHundred: Set<String>

    /// Words that join two numbers only when a number stands on both sides —
    /// "two hundred **and** forty", "vingt **et** un". Never a number by
    /// themselves, which is what keeps them out of ordinary prose.
    let connectors: [String: ConnectorKind]

    enum ConnectorKind { case and, point, oh }

    let twoDigit: TwoDigitRule

    /// Whether a scale word standing alone means one of itself. French `cent`
    /// and `mille` do — "cent cinquante" is 150. English "hundred" does not:
    /// it wants an "a" or a number in front, and treating a bare one as 100
    /// would fire on "hundreds of people".
    let bareScaleIsOne: Bool

    /// The article that stands in for one before a scale word, if the language
    /// has one. English "a hundred"; French has none, `un` being the unit.
    let articleOne: String?

    /// Words that stop the one before a bare scale word from being supplied.
    ///
    /// `bareScaleIsOne` is what makes "cent cinquante" 150, and the first thing
    /// it did once it worked was turn "soixante-quinze pour cent" into "75 pour
    /// 100". "pour cent" is a percent sign, not a number, and no amount of
    /// number grammar can tell — it is a fixed phrase, so it is listed as one.
    let bareScaleBlockers: Set<String>

    let decimalSeparator: String

    /// "1st" / "1er". Takes the value because both languages inflect on it.
    let ordinalSuffix: (Int) -> String

    /// The word a decimal point is spoken as is in `connectors`; this is what
    /// the language calls the digits after it, only used for logging.
    let code: String

    // MARK: - Lookup

    enum Word {
        case unit(Int)
        case teen(Int)
        case tens(Int)
        case hundred
        case scale(Int)
        case and
        case point
        case oh
    }

    func classify(_ word: String) -> (word: Word, ordinal: Bool)? {
        if let value = units[word] { return (.unit(value), false) }
        if let value = teens[word] { return (.teen(value), false) }
        if let value = tens[word] { return (.tens(value), false) }
        if hundred.contains(word) { return (.hundred, false) }
        if let value = scales[word] { return (.scale(value), false) }
        if let value = ordinalUnits[word] { return (.unit(value), true) }
        if let value = ordinalTeens[word] { return (.teen(value), true) }
        if let value = ordinalTens[word] { return (.tens(value), true) }
        if ordinalHundred.contains(word) { return (.hundred, true) }
        if let value = ordinalScales[word] { return (.scale(value), true) }
        return nil
    }

    func connector(_ word: String) -> Word? {
        switch connectors[word] {
        case .and: return .and
        case .point: return .point
        case .oh: return .oh
        case nil: return nil
        }
    }

    static func named(_ code: String) -> NumberGrammar {
        switch code {
        case "fr": return .french
        default: return .english
        }
    }
}
