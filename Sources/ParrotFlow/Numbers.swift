import Foundation

/// Writes spoken numbers as digits: "two hundred forty-three" => 243.
///
/// Not a substitution table — there are infinitely many numbers, and "forty"
/// means 40 in "forty-three" and 40,000 in "forty thousand". About seventy
/// words build every number in a language, so this parses a grammar over that
/// vocabulary instead of enumerating results.
///
/// English and French, chosen by `NumberGrammar` — the vocabulary and the three
/// rules that differ live there, and everything below is the same in both. What
/// is *not* in the grammar is the judgement that matters most: a lone number
/// word below `digitsFrom` stays a word, compounds convert whatever their size.
/// That is why "à deux, on a dépensé deux cents euros" keeps its `deux` and
/// writes 200, in exactly the way "just the two of us" already did.
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
    //
    // Moved to NumberGrammar and its per-language files. What is left in this
    // file is the machinery, which is the same in every language it supports.

    typealias Word = NumberGrammar.Word

    // MARK: - Entry point

    static func apply(to text: String, language: String = "en") -> String {
        apply(to: text, grammar: .named(language))
    }

    /// Reads the numbers in `text` using whichever configured language actually
    /// finds any.
    ///
    /// Detection alone is not enough, and the gap is not exotic. The recogniser
    /// needs four words to answer and returns the fallback below that, so "cent
    /// euros" and "vingt et un" — two of the commonest things anyone dictates —
    /// would be handed the English grammar and come back untouched. Its other
    /// known miss, code-switching, fails the same way on longer text.
    ///
    /// So the detected language is tried first and the rest of the configured
    /// list after it, stopping at the one that changes something.
    ///
    /// That fallback needs a guard, and the case that proved it was "I have 99
    /// cents": English finds nothing to do, French reads `cents` as its word
    /// for hundreds, and a correct sentence came back as "I have 99 100". The
    /// vocabularies do overlap, and where they overlap they do not agree — a
    /// French number word can be an ordinary word in English.
    ///
    /// So a language the recogniser did not choose has to bring more evidence
    /// than a bare scale word. When the text was long enough to identify —
    /// four words, `DictationLanguage`'s own floor — a candidate grammar is
    /// only allowed to win if it recognises a unit, a teen or a tens word
    /// somewhere: something that is unmistakably a number in that language.
    /// "vingt et un" clears that bar inside an otherwise English sentence,
    /// which is what keeps code-switching working; a lone "cents" does not.
    ///
    /// Below four words nothing can be identified, so the bar comes down and
    /// every configured grammar gets a turn — otherwise "cent euros" and
    /// "vingt et un", two of the commonest things anyone dictates, would be
    /// handed the wrong grammar and come back untouched.
    static func apply(to text: String, languages: [String]) -> String {
        read(text, languages: languages).text
    }

    /// The same pass, saying which grammar it was that read the numbers.
    ///
    /// That verdict has always been computed here and thrown away, and it is not
    /// the same answer as the pipeline's own language: the rule above is "try the
    /// detected one, then the others, and let a candidate win only on real
    /// evidence", so a French number inside an English sentence is read by the
    /// French grammar while the pipeline is still an English one. The pipeline
    /// publishes it as `numbers.language`, which is the first time anything has
    /// been able to see which grammar actually fired.
    ///
    /// When nothing changed there is no winner, and the detected language is
    /// reported — that is the grammar that was asked and declined, which is the
    /// useful answer to "why did this not become a digit".
    static func read(
        _ text: String, languages: [String]
    ) -> (text: String, language: String) {
        let fallback = languages.first ?? "en"
        let detected = DictationLanguage.detect(
            text, allowed: languages, fallback: fallback
        )

        let primary = apply(to: text, grammar: .named(detected))
        if primary != text { return (primary, detected) }

        let identifiable = text.split(whereSeparator: { $0.isWhitespace }).count
            >= DictationLanguage.minimumWords && languages.count > 1

        for language in languages where language != detected {
            let grammar = NumberGrammar.named(language)
            let output = apply(to: text, grammar: grammar)
            guard output != text else { continue }
            if identifiable, !hasPlainNumberWord(text, grammar) { continue }
            return (output, language)
        }
        return (text, detected)
    }

    /// Whether the text contains a word this grammar reads as a unit, a teen or
    /// a tens word — as opposed to only a scale word, which is where the two
    /// languages collide.
    private static func hasPlainNumberWord(_ text: String, _ grammar: NumberGrammar) -> Bool {
        tokenize(text).contains { token in
            switch grammar.classify(token.text)?.word {
            case .unit, .teen, .tens: return true
            default: return false
            }
        }
    }

    static func apply(to text: String, grammar: NumberGrammar) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        for run in runs(in: tokens, grammar: grammar) {
            replacements.append(contentsOf: convert(run: run, tokens: tokens, grammar: grammar))
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
        guard let pattern = Replacements.wordPattern else { return [] }
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
    private static func runs(in tokens: [Token], grammar: NumberGrammar) -> [[Item]] {
        var runs: [[Item]] = []
        var current: [Item] = []

        for (index, token) in tokens.enumerated() {
            let continues = !current.isEmpty && index > 0 && tokens[index - 1].joinedToNext
            var item: Item?

            // A scale word opening a run, right after a word that makes it a
            // fixed phrase, is not a number: "pour cent" is a percent sign.
            // Only when it *opens* one — "trois pour cent" leaves the three
            // alone but "deux cent trois" is untouched by this.
            let blocked = current.isEmpty && index > 0
                && grammar.bareScaleBlockers.contains(tokens[index - 1].text)
                && (grammar.hundred.contains(token.text) || grammar.scales[token.text] != nil)

            if blocked {
                runs.append(current)
                current = []
                continue
            }

            if let classified = grammar.classify(token.text) {
                item = Item(word: classified.word, ordinal: classified.ordinal, index: index)
            } else if let article = grammar.articleOne, token.text == article,
                token.joinedToNext, index + 1 < tokens.count,
                grammar.hundred.contains(tokens[index + 1].text)
                    || grammar.scales[tokens[index + 1].text] == 1_000 {
                // "a hundred and fifty" is a number said aloud; "a" anywhere
                // else is an article. Not extended to million and up: "a
                // million reasons" is a figure of speech, not a figure.
                item = Item(word: .unit(1), ordinal: false, index: index)
            } else if let connector = grammar.connector(token.text), continues,
                token.joinedToNext, index + 1 < tokens.count,
                grammar.classify(tokens[index + 1].text) != nil {
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

    private static func convert(
        run: [Item], tokens: [Token], grammar: NumberGrammar
    ) -> [(Range<String.Index>, String)] {
        var numbers: [Number] = []
        var index = 0
        while index < run.count {
            if let digits = digitRun(in: run, at: index, tokens: tokens) {
                numbers.append(digits)
                index = digits.end
            } else if let number = parseNumber(run, index, grammar), number.end > index {
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
            return (range, written(number, grammar))
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
    private static func parseTwoDigit(
        _ run: [Item], _ start: Int, _ grammar: NumberGrammar
    ) -> (value: Int, end: Int, ordinal: Bool)? {
        guard start < run.count else { return nil }
        if grammar.twoDigit == .vigesimal { return parseVigesimal(run, start, grammar) }

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

    /// Below 100 in a language that counts in twenties.
    ///
    /// Three shapes English does not have, and they compose:
    ///
    ///     soixante-dix            60 + 10          a tens word taking a teen
    ///     quatre-vingts           4 × 20           a unit multiplying a tens
    ///     quatre-vingt-dix-sept   4 × 20 + 10 + 7  both, and a teen taking a unit
    ///
    /// The multiplication is deliberately narrow — only four, only twenty. A
    /// general "unit times tens" rule would read "deux vingt" as 40, which is
    /// not French and would fabricate a number out of two ordinary words. Every
    /// widening here has to be paid for in tests/numbers-cases.yaml, because
    /// this is the function where a wrong answer looks like a right one.
    private static func parseVigesimal(
        _ run: [Item], _ start: Int, _ grammar: NumberGrammar
    ) -> (value: Int, end: Int, ordinal: Bool)? {
        let item = run[start]
        var base: Int
        var index: Int
        var ordinal = item.ordinal

        switch item.word {
        case .unit(4) where !item.ordinal
            && start + 1 < run.count
            && isTens(run[start + 1].word, 20)
            && !run[start + 1].ordinal:
            base = 80
            index = start + 2
        case .tens(let value):
            base = value
            index = start + 1
        case .unit(let value), .teen(let value):
            // "dix-sept" is one number, and arrives as two tokens because the
            // tokeniser splits hyphens. Only seven, eight and nine: "dix un"
            // is not a number, and reading it as one would make 11 out of a
            // sentence that said ten and one.
            if case .teen(10) = item.word, !item.ordinal, start + 1 < run.count,
                case .unit(let digit) = run[start + 1].word, (7...9).contains(digit) {
                return (10 + digit, start + 2, run[start + 1].ordinal)
            }
            return (value, start + 1, item.ordinal)
        default:
            return nil
        }
        guard !ordinal else { return (base, index, true) }

        // "vingt et un", "soixante et onze". The connector only survived into
        // the run with a number on both sides, so it cannot be prose here.
        var afterConnector = index
        if afterConnector < run.count, case .and = run[afterConnector].word {
            afterConnector += 1
        }
        guard afterConnector < run.count else { return (base, index, ordinal) }

        let tail = run[afterConnector]
        switch tail.word {
        // Only the sixties and eighties carry a teen: 70-79 and 90-99. Adding
        // one to any other tens word would read "trente douze" as 42.
        case .teen(let value) where base == 60 || base == 80:
            var total = base + value
            var end = afterConnector + 1
            if value == 10, end < run.count, case .unit(let digit) = run[end].word,
                (7...9).contains(digit), !tail.ordinal {
                total = base + 10 + digit
                ordinal = run[end].ordinal
                end += 1
            } else {
                ordinal = tail.ordinal
            }
            return (total, end, ordinal)
        case .unit(let digit) where digit > 0:
            return (base + digit, afterConnector + 1, tail.ordinal)
        default:
            return (base, index, ordinal)
        }
    }

    private static func isTens(_ word: Word, _ value: Int) -> Bool {
        if case .tens(let found) = word { return found == value }
        return false
    }

    /// Below 1000, with the British "and": "two hundred and forty-three".
    private static func parseHundreds(
        _ run: [Item], _ start: Int, _ grammar: NumberGrammar
    ) -> (value: Int, end: Int, ordinal: Bool, scaled: Bool)? {
        // "cent cinquante" is 150 with nothing in front of the hundred, where
        // English wants "a hundred" — a bare "hundreds of people" must not
        // become a number. Standing in a one here rather than in the vocabulary
        // keeps that difference to a single flag.
        var head: (value: Int, end: Int, ordinal: Bool)
        if grammar.bareScaleIsOne, case .hundred = run[start].word, !run[start].ordinal {
            head = (1, start, false)
        } else if let parsed = parseTwoDigit(run, start, grammar) {
            head = parsed
        } else {
            return nil
        }

        guard !head.ordinal, head.end < run.count, case .hundred = run[head.end].word else {
            return (head.value, head.end, head.ordinal, false)
        }

        let value = head.value * 100
        var index = head.end + 1
        if run[head.end].ordinal { return (value, index, true, true) }

        if index < run.count, case .and = run[index].word, parseTwoDigit(run, index + 1, grammar) != nil {
            index += 1
        }
        guard let tail = parseTwoDigit(run, index, grammar) else { return (value, index, false, true) }
        return (value + tail.value, tail.end, tail.ordinal, true)
    }

    /// One number, ending the moment the words stop describing one.
    private static func parseNumber(_ run: [Item], _ start: Int, _ grammar: NumberGrammar) -> Number? {
        var index = start
        var total = 0
        var lastScale = Int.max
        var ordinal = false
        var scaled = false
        var any = false

        while index < run.count {
            // "mille" on its own is a thousand. Same rule as a bare hundred,
            // and the same reason it is a flag: English "thousands of them" is
            // not 1000 of them.
            if grammar.bareScaleIsOne, case .scale(let scale) = run[index].word,
                !run[index].ordinal, scale < lastScale,
                parseHundreds(run, index, grammar) == nil {
                total += scale
                lastScale = scale
                scaled = true
                any = true
                index += 1
                continue
            }
            guard let group = parseHundreds(run, index, grammar) else { break }
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
                    parseHundreds(run, index + 1, grammar) != nil {
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
    private static func written(_ number: Number, _ grammar: NumberGrammar) -> String {
        if let literal = number.literal { return literal }
        if let fraction = number.fraction {
            return "\(number.value)\(grammar.decimalSeparator)\(fraction)"
        }
        if number.ordinal { return "\(number.value)\(grammar.ordinalSuffix(number.value))" }
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
