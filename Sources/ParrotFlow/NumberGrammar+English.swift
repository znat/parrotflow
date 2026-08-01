import Foundation

/// The English number vocabulary, moved out of `Numbers` unchanged.
///
/// Every table here is byte for byte what `Numbers.swift` held before the
/// grammar was made pluggable, including the comments explaining the two
/// deliberate omissions. The move was scored against tests/numbers-cases.yaml
/// to prove it changed nothing — a refactor that quietly alters behaviour is
/// worse than the duplication it removes.
extension NumberGrammar {

    static let english = NumberGrammar(
        units: [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
            "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        ],
        teens: [
            "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
            "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        ],
        tens: [
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        ],
        scales: [
            "thousand": 1_000, "million": 1_000_000,
            "billion": 1_000_000_000, "trillion": 1_000_000_000_000,
        ],
        hundred: ["hundred"],

        // "second" is deliberately missing. It is a unit of time far more often
        // than an ordinal here, and the collision is not decidable without
        // context: "a thirty second timeout" would become "a 32nd timeout".
        // Leaving it out costs "the twenty second of March" — which lands as
        // "the 20 second of March" — and buys back every spoken duration.
        ordinalUnits: [
            "first": 1, "third": 3, "fourth": 4, "fifth": 5,
            "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
        ],
        ordinalTeens: [
            "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
            "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
            "nineteenth": 19,
        ],
        ordinalTens: [
            "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
            "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        ],
        ordinalScales: [
            "thousandth": 1_000, "millionth": 1_000_000, "billionth": 1_000_000_000,
        ],
        ordinalHundred: ["hundredth"],

        connectors: ["and": .and, "point": .point, "oh": .oh],

        twoDigit: .additive,
        // "hundreds of people" is not 100 of people.
        bareScaleIsOne: false,
        // "a hundred and fifty" is a number said aloud; "a" anywhere else is an
        // article. Not extended past thousand: "a million reasons" is a figure
        // of speech, not a figure.
        articleOne: "a",
        // English says "per cent" as two words too, and "hundred" is not a
        // bare number here anyway, but the list costs nothing and documents
        // the shape.
        bareScaleBlockers: ["per"],
        decimalSeparator: ".",
        ordinalSuffix: { value in
            switch (value % 100, value % 10) {
            case (11, _), (12, _), (13, _): return "th"
            case (_, 1): return "st"
            case (_, 2): return "nd"
            case (_, 3): return "rd"
            default: return "th"
            }
        },
        code: "en"
    )
}
