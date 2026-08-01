import Foundation

/// French numbers.
///
/// Scored by tests/numbers-cases.yaml. The case that motivated the whole thing
/// is "à deux, on a dépensé deux cents euros": `deux` alone stays a word,
/// `deux cents` becomes 200. That distinction is not French-specific and is not
/// implemented here — it is `Numbers.digitsFrom` and the compound rule, which
/// already read that way in English. What was missing was only the vocabulary
/// and three combining rules.
///
/// The three, in the order they hurt:
///
///   - **70, 80, 90 are arithmetic.** `soixante-dix` is 60 + 10, `quatre-vingts`
///     is 4 × 20, `quatre-vingt-dix-sept` is 4 × 20 + 10 + 7. English's rule —
///     a tens word takes at most one unit — is what stops "ten fifteen" being
///     25, so French could not simply relax it; it gets its own, `.vigesimal`.
///   - **`et` joins.** `vingt et un`, `soixante et onze`. It is in `connectors`
///     rather than the vocabulary, so it only ever binds with a number on both
///     sides and cannot fire on ordinary French.
///   - **Bare scales count.** `cent cinquante` is 150 and `mille` is 1000,
///     where English "hundred" alone is not 100.
///
/// Hyphens do not appear in these tables on purpose. `Numbers.tokenize` splits
/// on them, so `quatre-vingt-dix-sept` arrives as four tokens and is read by
/// the same path as the same words spoken with spaces — which is what Parakeet
/// actually writes, and it varies between the two.
///
/// `seconde` is left out for the reason `second` is left out of English: it is
/// a unit of time more often than an ordinal, and "trente secondes" must not
/// become "30 2èmes".
extension NumberGrammar {

    static let french = NumberGrammar(
        units: [
            "zéro": 0, "zero": 0,
            // "une" is the same number and a very common article. It is safe
            // here only because a lone unit below ten stays a word — see
            // `Numbers.digitsFrom` — so "une question" is never touched.
            "un": 1, "une": 1,
            "deux": 2, "trois": 3, "quatre": 4, "cinq": 5,
            "six": 6, "sept": 7, "huit": 8, "neuf": 9,
        ],
        teens: [
            "dix": 10, "onze": 11, "douze": 12, "treize": 13,
            "quatorze": 14, "quinze": 15, "seize": 16,
        ],
        tens: [
            "vingt": 20, "vingts": 20,
            "trente": 30, "quarante": 40, "cinquante": 50, "soixante": 60,

            // Belgium and Switzerland, where the vigesimal detour does not
            // exist: 70, 80 and 90 are ordinary tens words. They live in the
            // same grammar rather than a `fr_BE` of their own because the two
            // vocabularies are disjoint — nobody says both "septante" and
            // "soixante-dix" — so a table holding both reads either speaker
            // without having to know which one is talking. Which is just as
            // well, since nothing upstream knows: `NLLanguageRecognizer`
            // reports French, not which French.
            //
            // They also need no new rule. `.vigesimal` already reads a tens
            // word plus a unit, so "septante-huit" is 78 by the same path that
            // makes "trente-deux" 32.
            "septante": 70, "septantes": 70,
            "octante": 80, "huitante": 80,
            "nonante": 90, "nonantes": 90,
        ],
        scales: [
            "mille": 1_000, "milles": 1_000,
            "million": 1_000_000, "millions": 1_000_000,
            "milliard": 1_000_000_000, "milliards": 1_000_000_000,
        ],
        hundred: ["cent", "cents"],

        ordinalUnits: [
            "premier": 1, "première": 1, "premiere": 1,
            // The form "premier" takes only when it follows a tens word:
            // "vingt et unième" is 21st, and without this it came back as
            // "20 et unième".
            "unième": 1, "unieme": 1,
            "deuxième": 2, "deuxieme": 2,
            "troisième": 3, "troisieme": 3, "quatrième": 4, "quatrieme": 4,
            "cinquième": 5, "cinquieme": 5, "sixième": 6, "sixieme": 6,
            "septième": 7, "septieme": 7, "huitième": 8, "huitieme": 8,
            "neuvième": 9, "neuvieme": 9,
        ],
        ordinalTeens: [
            "dixième": 10, "dixieme": 10, "onzième": 11, "onzieme": 11,
            "douzième": 12, "douzieme": 12, "treizième": 13, "treizieme": 13,
            "quatorzième": 14, "quatorzieme": 14, "quinzième": 15, "quinzieme": 15,
            "seizième": 16, "seizieme": 16,
        ],
        ordinalTens: [
            "vingtième": 20, "vingtieme": 20, "trentième": 30, "trentieme": 30,
            "quarantième": 40, "quarantieme": 40, "cinquantième": 50, "cinquantieme": 50,
            "soixantième": 60, "soixantieme": 60,
            "septantième": 70, "septantieme": 70,
            "octantième": 80, "octantieme": 80, "huitantième": 80, "huitantieme": 80,
            "nonantième": 90, "nonantieme": 90,
        ],
        ordinalScales: [
            "millième": 1_000, "millieme": 1_000,
            "millionième": 1_000_000, "millionieme": 1_000_000,
        ],
        ordinalHundred: ["centième", "centieme"],

        connectors: ["et": .and, "virgule": .point],

        twoDigit: .vigesimal,
        bareScaleIsOne: true,
        // None. French says "cent", not "un cent", and `un` is already the
        // unit — an article rule here would fire on every "un" in the language.
        articleOne: nil,
        // "pour cent" and "pour mille" are the percent and per-mille signs.
        bareScaleBlockers: ["pour"],
        decimalSeparator: ",",
        // 1er, then 2e, 3e. The feminine "1re" cannot be known from the number,
        // and the masculine is the form that reads acceptably either way.
        ordinalSuffix: { $0 == 1 ? "er" : "e" },
        code: "fr"
    )
}
