import Foundation

/// Writes spoken numbers as digits: "two hundred forty-three" => 243.
///
/// Not a substitution table — there are infinitely many numbers, and "forty"
/// means 40 in "forty-three" and 40,000 in "forty thousand". About seventy
/// words build every number in English, so this parses a grammar over that
/// vocabulary instead of enumerating results. English only; the French words
/// are absent from the maps, so a French transcript passes through untouched.
///
/// The arithmetic is the easy half. The hard half is knowing where a number
/// *ends*, because a plain accumulator sums whatever it is handed:
///
///     "let's meet at ten fifteen"     naive: 10 + 15 => 25
///
/// Wrong, and wrong in the worst way — it looks like a number someone said. So
/// every transition is checked instead. A unit or teen may only be followed by
/// a scale word; a tens word takes at most one unit; scale words must strictly
/// descend. Anything else ends the number and begins the next one, which makes
/// a fabricated value impossible: "ten fifteen" is two numbers, and comes out
/// as "10 15".
enum Numbers {

    /// Below this a lone number word stays a word. "chapter three" reads
    /// better than "chapter 3", and the floor is also what keeps "one" the
    /// pronoun and "a" the article out of reach. Compounds convert whatever
    /// their size, so "twenty-five" is 25 and "one hundred" is 100.
    static let digitsFrom = 10

    /// Consecutive spoken digits are a code, a phone number or a version — not
    /// arithmetic — and get concatenated rather than added. Two is enough to
    /// mean it; the guards in `digitRun` are what make a floor that low safe.
    static let digitRunLength = 2

    // MARK: - Vocabulary

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tensWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000,
        "billion": 1_000_000_000, "trillion": 1_000_000_000_000,
    ]

    /// "second" is deliberately missing. It is a unit of time far more often
    /// than an ordinal here, and the collision is not decidable without
    /// context: "a thirty second timeout" would become "a 32nd timeout".
    /// Leaving it out costs "the twenty second of March" — which lands as
    /// "the 20 second of March" — and buys back every spoken duration.
    private static let ordinalUnits: [String: Int] = [
        "first": 1, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]
    private static let ordinalTeens: [String: Int] = [
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    ]
    private static let ordinalTens: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]
    private static let ordinalScales: [String: Int] = [
        "thousandth": 1_000, "millionth": 1_000_000, "billionth": 1_000_000_000,
    ]

    /// Ordinary English words that only join a number when a number is on both
    /// sides of them — see `runs`.
    private static let connectors: [String: Word] = [
        "and": .and, "point": .point, "oh": .oh,
    ]

    private enum Word {
        case unit(Int)      // zero…nine
        case teen(Int)      // ten…nineteen
        case tens(Int)      // twenty…ninety
        case hundred
        case scale(Int)     // thousand…trillion
        case and
        case point
        case oh             // zero, but only mid-run: "five oh five"
    }

    private static func classify(_ word: String) -> (word: Word, ordinal: Bool)? {
        if let value = units[word] { return (.unit(value), false) }
        if let value = teens[word] { return (.teen(value), false) }
        if let value = tensWords[word] { return (.tens(value), false) }
        if word == "hundred" { return (.hundred, false) }
        if let value = scales[word] { return (.scale(value), false) }
        if let value = ordinalUnits[word] { return (.unit(value), true) }
        if let value = ordinalTeens[word] { return (.teen(value), true) }
        if let value = ordinalTens[word] { return (.tens(value), true) }
        if word == "hundredth" { return (.hundred, true) }
        if let value = ordinalScales[word] { return (.scale(value), true) }
        return nil
    }

    // MARK: - Entry point

    static func apply(to text: String) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        for run in runs(in: tokens) {
            replacements.append(contentsOf: convert(run: run, tokens: tokens))
        }
        guard !replacements.isEmpty else { return text }

        var output = text
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            Log.write("numbers: \"\(text[replacement.range])\" → \(replacement.text)")
            output.replaceSubrange(replacement.range, with: replacement.text)
        }
        return output
    }

    // MARK: - Tokens and runs

    private struct Token {
        let text: String                // lowercased
        let range: Range<String.Index>
        /// Nothing but spaces or hyphens before the next token. Punctuation
        /// ends a number: "two, three others" is not 23.
        let joinedToNext: Bool
        /// Specifically a hyphen, which binds "three" to "inch" in
        /// "two three-inch bolts" and has to stop the digit run there.
        let hyphenToNext: Bool
    }

    private struct Item {
        let word: Word
        let ordinal: Bool
        let index: Int                  // into the token array
    }

    private static func tokenize(_ text: String) -> [Token] {
        guard let pattern = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}']+") else { return [] }
        let ranges = pattern
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }

        return ranges.enumerated().map { position, range in
            var joined = false
            var hyphen = false
            if position + 1 < ranges.count {
                let gap = text[range.upperBound..<ranges[position + 1].lowerBound]
                joined = gap.allSatisfy { $0.isWhitespace || $0 == "-" || $0 == "\u{2011}" }
                hyphen = joined && gap.contains { $0 == "-" || $0 == "\u{2011}" }
            }
            return Token(
                text: text[range].lowercased(),
                range: range,
                joinedToNext: joined,
                hyphenToNext: hyphen
            )
        }
    }

    /// Maximal stretches of adjacent number words. Every item in a run is a
    /// consecutive token, which is what later lets adjacency be tested on run
    /// positions alone.
    private static func runs(in tokens: [Token]) -> [[Item]] {
        var runs: [[Item]] = []
        var current: [Item] = []

        for (index, token) in tokens.enumerated() {
            let continues = !current.isEmpty && index > 0 && tokens[index - 1].joinedToNext
            var item: Item?

            if let classified = classify(token.text) {
                item = Item(word: classified.word, ordinal: classified.ordinal, index: index)
            } else if token.text == "a", token.joinedToNext, index + 1 < tokens.count,
                ["hundred", "thousand"].contains(tokens[index + 1].text) {
                // "a hundred and fifty" is a number said aloud; "a" anywhere
                // else is an article. Not extended to million and up: "a
                // million reasons" is a figure of speech, not a figure.
                item = Item(word: .unit(1), ordinal: false, index: index)
            } else if let connector = connectors[token.text], continues,
                token.joinedToNext, index + 1 < tokens.count,
                classify(tokens[index + 1].text) != nil {
                // Number words on both sides, or it is just English: "one and
                // two came back", "the point five people missed".
                item = Item(word: connector, ordinal: false, index: index)
            }

            guard let item else {
                if !current.isEmpty { runs.append(current); current = [] }
                continue
            }
            if !current.isEmpty, !continues { runs.append(current); current = [] }
            current.append(item)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    // MARK: - Parsing

    private struct Number {
        var value = 0
        /// Digits kept as written, for runs where their order is the point and
        /// leading zeros must survive: "zero one two" is 012, not 12.
        var literal: String?
        var fraction: String?
        var ordinal = false
        /// One two-digit group, no hundred and no scale — the shape the year
        /// rule pairs up.
        var simple = false
        /// Written as digits whatever the threshold says.
        var forced = false
        /// Left as words whatever the threshold says.
        var held = false
        var begin = 0                   // run position, inclusive
        var end = 0                     // run position, exclusive
        var words: Int { end - begin }
    }

    private static func convert(run: [Item], tokens: [Token]) -> [(Range<String.Index>, String)] {
        var numbers: [Number] = []
        var index = 0
        while index < run.count {
            if let digits = digitRun(in: run, at: index, tokens: tokens) {
                numbers.append(digits)
                index = digits.end
            } else if let number = parseNumber(run, index), number.end > index {
                numbers.append(number)
                index = number.end
            } else {
                index += 1
            }
        }

        return pairGroups(numbers).compactMap { number in
            let wanted = !number.held && (number.forced
                || number.fraction != nil
                || number.value >= digitsFrom
                || number.words >= 2)
            guard wanted else { return nil }
            let range = tokens[run[number.begin].index].range.lowerBound
                ..< tokens[run[number.end - 1].index].range.upperBound
            return (range, written(number))
        }
    }

    /// Spoken digits, concatenated rather than added.
    ///
    /// The guards are the whole reason a two-digit floor is safe. A scale word
    /// on either side means the digits belong to it — "two three hundred" is 2
    /// and 300, not 23 hundred — and a hyphen on the right means the last digit
    /// belongs to the word after it, as in "two three-inch bolts".
    private static func digitRun(in run: [Item], at start: Int, tokens: [Token]) -> Number? {
        guard case .unit(let first) = run[start].word, !run[start].ordinal else { return nil }

        var digits = String(first)
        var end = start + 1
        while end < run.count {
            if case .unit(let digit) = run[end].word, !run[end].ordinal {
                digits += String(digit)
            } else if case .oh = run[end].word {
                digits += "0"
            } else {
                break
            }
            end += 1
        }
        guard end - start >= digitRunLength else { return nil }

        if start > 0 {
            switch run[start - 1].word {
            case .tens, .hundred, .scale, .point: return nil
            default: break
            }
        }
        if end < run.count {
            switch run[end].word {
            case .hundred, .scale, .point: return nil
            default: break
            }
        } else if tokens[run[end - 1].index].hyphenToNext {
            return nil
        }

        return Number(literal: digits, forced: true, begin: start, end: end)
    }

    /// Below 100: a unit, a teen, or a tens word taking one unit.
    private static func parseTwoDigit(_ run: [Item], _ start: Int) -> (value: Int, end: Int, ordinal: Bool)? {
        guard start < run.count else { return nil }
        let item = run[start]
        switch item.word {
        case .unit(let value), .teen(let value):
            return (value, start + 1, item.ordinal)
        case .tens(let value):
            if !item.ordinal, start + 1 < run.count, case .unit(let digit) = run[start + 1].word,
                digit > 0 {
                return (value + digit, start + 2, run[start + 1].ordinal)
            }
            return (value, start + 1, item.ordinal)
        default:
            return nil
        }
    }

    /// Below 1000, with the British "and": "two hundred and forty-three".
    private static func parseHundreds(
        _ run: [Item], _ start: Int
    ) -> (value: Int, end: Int, ordinal: Bool, scaled: Bool)? {
        guard let head = parseTwoDigit(run, start) else { return nil }
        guard !head.ordinal, head.end < run.count, case .hundred = run[head.end].word else {
            return (head.value, head.end, head.ordinal, false)
        }

        let value = head.value * 100
        var index = head.end + 1
        if run[head.end].ordinal { return (value, index, true, true) }

        if index < run.count, case .and = run[index].word, parseTwoDigit(run, index + 1) != nil {
            index += 1
        }
        guard let tail = parseTwoDigit(run, index) else { return (value, index, false, true) }
        return (value + tail.value, tail.end, tail.ordinal, true)
    }

    /// One number, ending the moment the words stop describing one.
    private static func parseNumber(_ run: [Item], _ start: Int) -> Number? {
        var index = start
        var total = 0
        var lastScale = Int.max
        var ordinal = false
        var scaled = false
        var any = false

        while index < run.count {
            guard let group = parseHundreds(run, index) else { break }
            if group.scaled { scaled = true }

            // A scale word closes the group and opens the next, and they have
            // to descend: "two thousand three thousand" is two numbers.
            if !group.ordinal, group.end < run.count, case .scale(let scale) = run[group.end].word,
                scale < lastScale {
                total += group.value * scale
                lastScale = scale
                scaled = true
                any = true
                index = group.end + 1
                if run[group.end].ordinal { ordinal = true; break }
                if index < run.count, case .and = run[index].word,
                    parseHundreds(run, index + 1) != nil {
                    index += 1
                }
                continue
            }

            total += group.value
            ordinal = group.ordinal
            index = group.end
            any = true
            break
        }
        guard any else { return nil }

        var number = Number(
            value: total, ordinal: ordinal, simple: !scaled, begin: start, end: index
        )

        // "three point one four" — single digits after the point, which is how
        // a decimal is spoken. Anything else ends the number.
        if !ordinal, index < run.count, case .point = run[index].word {
            var scan = index + 1
            var fraction = ""
            while scan < run.count {
                if case .unit(let digit) = run[scan].word, !run[scan].ordinal {
                    fraction += String(digit)
                } else if case .oh = run[scan].word {
                    fraction += "0"
                } else {
                    break
                }
                scan += 1
            }
            if !fraction.isEmpty {
                number.fraction = fraction
                number.simple = false
                number.end = scan
            }
        }
        return number
    }

    /// Settles what numbers standing side by side were meant to be.
    ///
    /// "nineteen eighty-four" parses as 19 then 84 — correctly, since that is
    /// all the words say. Pairing them back into a year is a separate, narrower
    /// rule, and the leading group is held to 13–20: that covers 1300–2099,
    /// which is every year anyone dictates, and it stops short of ten, eleven
    /// and twelve, where a clock time would be indistinguishable from one.
    ///
    /// Anything still adjacent afterwards is left as words. Two numbers the
    /// parser could not read as one are a time, a ratio or a hesitation —
    /// "eleven thirty", "sixty forty split", "nine eleven" — and writing them
    /// out separately produces "11 30" and "nine 11", which nobody would type.
    /// Refusing to guess is the one option that cannot make a transcript that
    /// was already right worse.
    private static func pairGroups(_ numbers: [Number]) -> [Number] {
        var result: [Number] = []
        var index = 0
        while index < numbers.count {
            let current = numbers[index]
            if index + 1 < numbers.count {
                let next = numbers[index + 1]
                // Standalone pair only. In a longer chain of adjacent groups —
                // "ten fifteen twenty" — a year is not what any two of them
                // are, and taking the middle two produced "10 1520".
                let isolated = (index == 0 || numbers[index - 1].end != current.begin)
                    && (index + 2 >= numbers.count || numbers[index + 2].begin != next.end)
                if isolated,
                    current.simple, next.simple, !current.ordinal, !next.ordinal,
                    current.fraction == nil, next.fraction == nil,
                    next.begin == current.end,
                    (13...20).contains(current.value), (10...99).contains(next.value) {
                    result.append(Number(
                        value: current.value * 100 + next.value,
                        forced: true, begin: current.begin, end: next.end
                    ))
                    index += 2
                    continue
                }
            }
            result.append(current)
            index += 1
        }

        for position in result.indices.dropLast() where result[position].end == result[position + 1].begin {
            guard !result[position].forced, !result[position + 1].forced else { continue }
            result[position].held = true
            result[position + 1].held = true
        }
        return result
    }

    // MARK: - Writing

    /// No thousands separators anywhere: a comma reads well in prose and badly
    /// in the terminals and code fields this app pastes into.
    private static func written(_ number: Number) -> String {
        if let literal = number.literal { return literal }
        if let fraction = number.fraction { return "\(number.value).\(fraction)" }
        if number.ordinal { return "\(number.value)\(ordinalSuffix(number.value))" }
        return String(number.value)
    }

    private static func ordinalSuffix(_ value: Int) -> String {
        switch (value % 100, value % 10) {
        case (11, _), (12, _), (13, _): return "th"
        case (_, 1): return "st"
        case (_, 2): return "nd"
        case (_, 3): return "rd"
        default: return "th"
        }
    }
}
