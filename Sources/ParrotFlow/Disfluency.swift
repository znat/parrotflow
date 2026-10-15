/// The string rules of `built-in/transforms/disfluency/disfluency.py`, ported scalar for scalar. Python
/// offsets are code points, so every index here counts `Unicode.Scalar`s, and tokens are compared as scalar
/// arrays: Swift's `String ==` is canonical equivalence, Python's is code points.
enum Disfluency {
    /// What `applied` names, one per cut.
    enum Cut: String {
        case falseStart = "false start"
        case phraseRestarted = "phrase restarted"
        case wordRestarted = "word restarted"
        case phraseSaidTwice = "phrase said twice"
        case wordSaidTwice = "word said twice"
        // No Python twin: disfluency.py has no correction rule.
        case selfCorrection = "self-correction"
        case restartCommand = "restart command"
    }

    struct Outcome {
        var text: String
        /// One entry per cut, in the order made, repeats kept (Python's `applied` list).
        var cuts: [Cut]
    }

    struct Cleaned {
        var text: String
        /// One entry per cut, string passes first, then the corrections.
        var applied: [String]
        var declined: String
    }

    /// The corrections run last: by then "I mean I mean" is one marker. `parser` is asked only for English
    /// text that says a marker or a restart command. It waits for the parser, and fails only when the load did.
    /// `original` is the transcript before any stage: the hesitations a `fillers` table removed are cues.
    static func clean(
        _ text: String, original: String? = nil, language: String, parser: () async -> Result<Parser, Error>
    ) async -> Cleaned {
        let done = collapse(text)
        var cleaned = Cleaned(text: done.text, applied: done.cuts.map(\.rawValue), declined: "")
        guard language == "en", mentionsCorrection(done.text, original: original) else { return cleaned }
        switch await parser() {
        case .failure(let error):
            cleaned.declined = "corrections: the parser did not load (\(error.localizedDescription))"
        case .success(let parser):
            let fixed = correct(done.text, original: original) { parser.parse(words: $0, language: "en") }
            cleaned.text = fixed.text
            cleaned.applied += fixed.cuts.map(\.rawValue)
        }
        return cleaned
    }

    static func collapse(_ text: String) -> Outcome {
        var transcript = Transcript(Array(text.unicodeScalars))
        var cuts: [Cut] = []
        var before: [Unicode.Scalar]
        // To a fixed point: a dropped fragment can expose a new repetition ("w we we can").
        repeat {
            before = transcript.scalars
            for pass in passes {
                while let edit = pass(transcript) {
                    cuts.append(edit.cut)
                    transcript = transcript.cut(edit.first, upto: edit.upto)
                }
            }
        } while transcript.scalars != before
        return Outcome(text: String(String.UnicodeScalarView(transcript.scalars)), cuts: cuts)
    }

    private struct Edit {
        let first: Int
        let upto: Int
        let cut: Cut
    }

    /// In this order, each run to its own fixed point. Each returns the first cut it would make.
    private static let passes: [@Sendable (Transcript) -> Edit?] = [
        { firstFragment($0) },
        { firstRestart($0) },
        { firstPartial($0) },
        { firstRepeat($0) },
    ]

    /// Longest repeated phrase considered: "how long does it take how long does it take" is five words.
    private static let maxPhrase = 6

    /// A single letter begun and restarted: "I mean w we can try". A longer fragment ("in the tr in the
    /// terminal") is not reached. 2 examples in the archive, one a counter-example, so this is tuned to miss.
    private static func firstFragment(_ t: Transcript) -> Edit? {
        for i in t.words.indices.dropLast() {
            let fragment = t.raw(i)
            // Lowercase only: an uppercase letter is how this decoder writes a letter being named or spelled.
            guard isLetter(fragment), fragment.first?.properties.isLowercase == true,
                  !singleLetterWords.contains(fragment),
                  t.raw(i + 1).count >= 2, t.bare[i + 1].starts(with: fragment),
                  // A single letter among single letters is a spelling, not a stutter.
                  !isLetter(t.raw(i - 1)), !isLetter(t.raw(i + 2)),
                  // "b. bananas" is a list label, not a false start.
                  !t.stops(after: i)
            else { continue }
            return Edit(first: i, upto: i + 1, cut: .falseStart)
        }
        return nil
    }

    /// A phrase begun and begun again: "in the ter in the terminal". The `n-1` words that match exactly are
    /// the evidence, so no word list: 22 of the 30 archive fires have a partial that is an ordinary word.
    /// 30 fires over 8291 archive dictations, no failure found.
    private static func firstRestart(_ t: Transcript) -> Edit? {
        for n in stride(from: maxPhrase, through: 2, by: -1) {
            for i in t.pairStarts(n) {
                let begun = t.bare[i + n - 1], said = t.bare[i + 2 * n - 1]
                guard t.bare[i..<i + n - 1] == t.bare[i + n..<i + 2 * n - 1],
                      isBegun(begun, completedBy: said),
                      !neverCollapse.contains(begun), !neverCollapse.contains(said),
                      !t.stops(after: i + n - 1)
                else { continue }
                return Edit(first: i, upto: i + n, cut: .phraseRestarted)
            }
        }
        return nil
    }

    /// A word begun and said in full: "co could you check". Over 8291 dictations: 142 bare fires, 55 after
    /// the function words, 61 with the clitic rule, one failure, which the stop check catches.
    private static func firstPartial(_ t: Transcript) -> Edit? {
        for i in t.words.indices.dropLast() {
            let begun = t.bare[i], said = t.bare[i + 1]
            guard isBegun(begun, completedBy: said),
                  !neverStart.contains(begun), !neverCollapse.contains(begun)
            else { continue }
            // "it it's", "we we're". A hyphen is not a clitic: "peut peut-être" is two words.
            let next = said.dropFirst(begun.count).first
            let clitic = next == "'" || next == "\u{2019}"
            guard !functionWords.contains(begun) || clitic,
                  !isLetter(t.raw(i - 1)), !isLetter(t.raw(i + 2)),
                  !t.stops(after: i)
            else { continue }
            return Edit(first: i, upto: i + 1, cut: .wordRestarted)
        }
        return nil
    }

    /// The earlier copy goes; the last carries the trailing punctuation. Longest first: a short match
    /// collapsed first can hide a longer one.
    private static func firstRepeat(_ t: Transcript) -> Edit? {
        for n in stride(from: maxPhrase, through: 1, by: -1) {
            for i in t.pairStarts(n) where t.bare[i..<i + n] == t.bare[i + n..<i + 2 * n] {
                let pair = Repeat(transcript: t, i: i, n: n)
                if kept.contains(where: { $0(pair) }) { continue }
                return Edit(first: i, upto: i + n, cut: n > 1 ? .phraseSaidTwice : .wordSaidTwice)
            }
        }
        return nil
    }

    private static func isBegun(_ begun: [Unicode.Scalar], completedBy said: [Unicode.Scalar]) -> Bool {
        begun.count >= 2 && begun != said && said.starts(with: begun)
    }

    private struct Repeat {
        let transcript: Transcript
        let i: Int
        let n: Int

        var unit: ArraySlice<[Unicode.Scalar]> { transcript.bare[i..<i + n] }
        var raw: [[Unicode.Scalar]] { (i..<i + n).map(transcript.raw) }
        var neighbours: [[Unicode.Scalar]] { [transcript.raw(i - 1), transcript.raw(i + 2 * n)] }
        var stops: Bool { transcript.stops(after: i + n - 1) }

        /// "I I want": the pronoun twice, not the letter. The run of "I" opens a clause and a lowercase word
        /// follows it. "World War I I think", "Use option I I guess" and "My initials are I I." are letters.
        var isPronounStutter: Bool {
            guard n == 1, raw == [["I"]] else { return false }
            var first = i, last = i + 1
            while first > 0, transcript.raw(first - 1) == ["I"] { first -= 1 }
            while transcript.raw(last + 1) == ["I"] { last += 1 }
            let after = transcript.raw(last + 1)
            guard after.count >= 2, after.first?.properties.isLowercase == true else { return false }
            guard first > 0 else { return true }
            return transcript.pauses(after: first - 1) || stutterBefore.contains(transcript.bare[first - 1])
        }
    }

    /// Reasons to keep a repeat. Every one of these was a real transcript the naive rule damaged.
    private static let kept: [@Sendable (Repeat) -> Bool] = [
        { $0.unit.contains(where: neverCollapse.contains) },
        // A number read as digits: losing one is unrecoverable.
        { $0.unit.contains(where: isDigits) },
        { $0.n > 1 && $0.unit.contains(where: conjunctions.contains) },
        // Spelled aloud: one doubled capital, or a run of letters. The capital test is n == 1 only: scanning
        // a longer run kept every English repeat holding "I", as in "I mean I mean".
        { pair in
            (pair.n == 1 && pair.raw.allSatisfy { isLetter($0) && $0.first?.properties.isUppercase == true }
                && !pair.isPronounStutter)
                || (pair.n > 1 && pair.raw.allSatisfy(isLetter))
        },
        // A lone lower-case letter is only a spelling if it sits among letters.
        { pair in
            pair.n == 1 && pair.raw.allSatisfy(isLetter) && pair.neighbours.contains(where: isLetter)
                && !pair.isPronounStutter
        },
        // "Sorry, sorry, I forgot" apologises once. A longer repeat holding it is a stutter.
        { $0.n == 1 && $0.unit.first == Array("sorry".unicodeScalars) },
        { $0.stops },
    ]

    private static func words(_ list: [String]) -> Set<[Unicode.Scalar]> {
        Set(list.map { Array($0.unicodeScalars) })
    }

    /// Said twice on purpose: collapsing changes the meaning.
    private static let neverCollapse = words([
        "blah", "dot",                      // idiom, dictated ellipsis
        "yeah", "oui", "non", "si", "no",   // doubled is still one
        "that", "had",                      // "that that person said", "I had had enough"
        "very", "très", "tres",             // emphasis is the second copy
        "vous", "nous",                     // French reflexive: "vous vous êtes" needs both
        "ha", "la",                         // laughter, singing
    ]).union(numberWords)

    /// "numbers" does not catch every form ("twenty two two"), and collapsing one changes the value.
    private static let numberWords = words([
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "thousand", "million", "billion",
        "zéro", "un", "une", "deux", "trois", "quatre", "cinq", "sept", "huit",
        "neuf", "dix", "onze", "douze", "treize", "quatorze", "quinze", "seize",
        "vingt", "trente", "quarante", "cinquante", "soixante", "cent", "cents",
        "mille", "milliard",
    ])

    /// A phrase holding one is a list ("again and again"), not a stutter.
    private static let conjunctions = words(["and", "or", "et", "ou", "but", "mais", "nor", "ni"])

    /// Single letters that are real words: deleting one as a false start breaks the sentence.
    private static let singleLetterWords = words([
        "a", "i",   // EN: "I imagine", "a answer"
        "à",        // FR: "il a acheté"
        "y",        // FR: "il y a"
        "o", "ô",   // FR vocative
    ])

    /// A function word before a longer word with the same start is two ordinary words: "one on one", "we
    /// were", "il a acheté". Over 8291 archive dictations the bare prefix shape fires 142 times, this list
    /// takes it to 55, about 52 of them real. A dictionary keeps only 18 and loses "issue issues".
    private static let functionWords = words([
        // EN
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "his",
        "her", "its", "our", "their", "i", "you", "he", "she", "it", "we", "they",
        "me", "him", "them", "us", "am", "is", "are", "was", "were", "be", "been",
        "being", "do", "does", "did", "done", "have", "has", "had", "can", "could",
        "will", "would", "shall", "should", "may", "might", "must", "and", "or",
        "but", "nor", "so", "yet", "for", "in", "on", "at", "to", "of", "by",
        "with", "from", "into", "over", "under", "about", "after", "before", "no",
        "not", "very", "too", "more", "most", "as", "if", "then", "than", "there",
        "here", "when", "where",
        // FR
        "le", "la", "les", "un", "une", "des", "du", "de", "ma", "mon", "mes",
        "ta", "ton", "tes", "sa", "son", "ses", "notre", "nos", "votre", "vos",
        "leur", "leurs", "je", "tu", "il", "elle", "nous", "vous", "ils", "elles",
        "on", "me", "te", "se", "lui", "y", "en", "et", "ou", "mais", "donc",
        "ni", "car", "si", "que", "qui", "quoi", "dont", "est", "sont", "suis",
        "es", "sommes", "êtes", "ont", "ai", "as", "avons", "avez", "avait",
        "était", "dans", "sur", "au", "aux", "pour", "par", "avec", "sans",
        "sous", "vers", "chez", "ne", "pas", "plus", "très", "trop", "bien",
        "déjà", "encore", "peut", "veut", "doit", "faut", "peux", "veux", "dois",
        "vais", "va", "vont", "fait", "font",
    ])

    /// What may come before a stuttered "I I": a function word or a filler opens a clause, a content word
    /// ("option I I") names a letter.
    private static let stutterBefore = functionWords.union(words(["well", "okay", "ok", "yeah", "um", "uh", "oh", "like"]))

    /// Short words this speaker says that no function-word list holds: "the sequence of pr proposed" is a
    /// pull request. The transform cannot read vocabulary.yaml, so the escape hatch is here.
    private static let neverStart = words(["pr", "prs", "qa", "ui", "ux", "id", "db", "os", "ci", "cd"])

    /// Python's `is_letter`: one scalar, a letter.
    private static func isLetter(_ token: [Unicode.Scalar]) -> Bool {
        token.count == 1 && token.first?.isAlpha == true
    }

    /// Python's `str.isdigit()`.
    private static func isDigits(_ token: [Unicode.Scalar]) -> Bool {
        !token.isEmpty && token.allSatisfy { [.decimal, .digit].contains($0.properties.numericType) }
    }

    /// Python's `str.lower()`. Swift's mapping always gives σ for Σ; Python gives ς at the end of a cased
    /// run, by CPython's `handle_capital_sigma`.
    fileprivate static func lowered(_ word: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        for (i, scalar) in word.enumerated() {
            if scalar == "\u{3A3}" {
                out.append(isFinalSigma(word, at: i) ? "\u{3C2}" : "\u{3C3}")
            } else {
                out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return out
    }

    private static func isFinalSigma(_ word: [Unicode.Scalar], at i: Int) -> Bool {
        let before = word[..<i].last { !$0.properties.isCaseIgnorable }
        guard before?.properties.isCased == true else { return false }
        let after = word[(i + 1)...].first { !$0.properties.isCaseIgnorable }
        return after?.properties.isCased != true
    }
}

/// The text cut into Python's `WORD.finditer` matches.
private struct Transcript {
    let scalars: [Unicode.Scalar]
    /// Maximal runs of `[\wÀ-ɏ'’-]`. A dot is not in it, so "x.y" is two words.
    let words: [Range<Int>]
    let bare: [[Unicode.Scalar]]

    init(_ scalars: [Unicode.Scalar]) {
        var words: [Range<Int>] = []
        var start: Int?
        for (at, scalar) in scalars.enumerated() {
            if scalar.isWordPart {
                if start == nil { start = at }
            } else if let from = start {
                words.append(from..<at)
                start = nil
            }
        }
        if let from = start { words.append(from..<scalars.count) }
        self.scalars = scalars
        self.words = words
        bare = words.map { Disfluency.lowered(Array(scalars[$0])) }
    }

    /// The word as spelled, or empty past either end, as Python's `""` stand-in.
    func raw(_ i: Int) -> [Unicode.Scalar] {
        words.indices.contains(i) ? Array(scalars[words[i]]) : []
    }

    func pairStarts(_ n: Int) -> Range<Int> {
        0..<max(0, words.count - 2 * n + 1)
    }

    /// A sentence end (`[.!?…]`) between word `i` and the next: two copies across it are two sentences.
    func stops(after i: Int) -> Bool {
        guard i >= 0, i + 1 < words.count else { return false }
        return scalars[words[i].upperBound..<words[i + 1].lowerBound].contains(where: \.isSentenceEnd)
    }

    func sentenceStart(_ i: Int) -> Int {
        var s = i
        while s > 0, !stops(after: s - 1) { s -= 1 }
        return s
    }

    func sentenceEnd(_ i: Int) -> Int {
        var e = i
        while e + 1 < words.count, !stops(after: e) { e += 1 }
        return e
    }

    /// A stop, comma, semicolon or colon between word `i` and the next.
    func pauses(after i: Int) -> Bool {
        guard i >= 0, i + 1 < words.count else { return false }
        return scalars[words[i].upperBound..<words[i + 1].lowerBound].contains {
            $0.isSentenceEnd || $0 == "," || $0 == ";" || $0 == ":"
        }
    }

    /// Python's `cut_to`: words `first..<upto` and the gap after them go, and the case the first one carried
    /// stays: "The the prompt" -> "The prompt".
    func cut(_ first: Int, upto: Int) -> Transcript {
        var tail = Array(scalars[words[upto].lowerBound...])
        if raw(first).first?.properties.isUppercase == true,
           let lead = tail.first, lead.properties.isLowercase {
            tail.replaceSubrange(0..<1, with: lead.properties.uppercaseMapping.unicodeScalars)
        }
        return Transcript(Array(scalars[..<words[first].lowerBound]) + tail)
    }
}

private extension Unicode.Scalar {
    /// Python's `str.isalpha()` on one character.
    var isAlpha: Bool {
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    /// Python's `\w`.
    var isWord: Bool {
        isAlpha || properties.numericType != nil || self == "_"
    }

    /// `[\wÀ-ɏ'’-]`. The range also holds × and ÷, which are not `\w`.
    var isWordPart: Bool {
        isWord || (0xC0...0x24F).contains(value) || self == "'" || self == "\u{2019}" || self == "-"
    }

    /// Python's `\s`.
    var isSpace: Bool {
        properties.isWhitespace || (0x1C...0x1F).contains(value)
    }

    var isSentenceEnd: Bool {
        self == "." || self == "!" || self == "?" || self == "\u{2026}"
    }
}

// MARK: - Spoken corrections

/// "with Peter, no, with James", "with Peter. I mean James.", "… Let me restart. …". The string finds the
/// marker and the words that repeat across it; the parrot-syrinx tree decides whether the marker is one and
/// whether the repair stands in for what it replaces.
extension Disfluency {
    private static func phrases(_ list: [String]) -> [[[Unicode.Scalar]]] {
        list.map { $0.split(separator: " ").map { Array($0.unicodeScalars) } }
    }

    private static let correctionMarkers = phrases([
        "i mean", "i meant", "no", "sorry", "or rather", "wait", "actually", "scratch that", "strike that",
    ])
    /// Heard between a slip and its repair: "uh", "umm", "uhm", "er", "erm", "hm". A `fillers` table may have
    /// removed them before this stage runs.
    private static func hesitates(_ word: [Unicode.Scalar]) -> Bool {
        if [["e", "r"], ["e", "r", "m"], ["h", "m"], ["h", "m", "m"]].contains(word) { return true }
        let held = word.drop { $0 == "u" }
        return held.count < word.count && !held.isEmpty && held.allSatisfy { $0 == "h" || $0 == "m" }
    }
    /// They may open a marker, "Ah no, James.", but say nothing on their own.
    private static let openers = words(["ah", "oh"])
    /// A word right after "no" that "no" cannot be the determiner of: "some pork no some chicken".
    private static let determiners = words([
        "the", "a", "an", "some", "this", "that", "these", "those", "my", "your", "his", "her", "its", "our",
        "their", "any",
    ])
    /// After a full stop. "Sorry" there apologises again, and "no" after a question answers it.
    private static let afterStop = phrases(["i mean", "i meant", "no"])
    /// The marker in its ordinary sense, said before the very word a restart would repeat.
    private static let idioms = phrases([
        "sorry for", "sorry about", "sorry to", "sorry if", "sorry that", "no matter", "no longer", "no more",
        "wait for", "wait until", "wait till",
    ])
    /// Said as their own clause, they take back the sentence before.
    private static let restartCommands = phrases([
        "scratch that", "strike that", "let me rephrase", "let me rephrase that",
    ])
    /// These also say what they mean literally ("The server froze. Let me restart."), so the next sentence
    /// must say the dropped one again with a word or two changed.
    private static let ambiguousRestartCommands = phrases([
        "let me restart", "let me start over", "let me start again", "let me try again", "let me say that again",
        "start over",
    ])
    /// A sentence that says one of these is not one a restart command takes back: "I'll rephrase."
    private static let commandWords = words(["restart", "rephrase", "scratch", "strike"])
    /// Common English words that French and Spanish do not share. `DictationLanguage` knows only English and
    /// French, so "con Pedro, no, con Juan" arrives as English.
    private static let englishWords = words([
        "the", "to", "with", "and", "is", "it", "you", "of", "for", "that", "we", "my", "this", "be", "are",
        "was", "in", "have", "do", "not", "can", "will", "i", "i'm", "it's", "what", "at", "he", "she", "they",
        "but", "just", "from", "your", "our", "if", "so", "his", "him", "her", "them", "us", "their", "were",
        "been", "has", "had", "would", "could", "should", "don't", "i'll", "we'll", "that's", "who", "how",
        "there", "about", "up", "out", "please", "let", "let's", "send", "call", "need", "want", "tell", "ask",
        "use", "put", "move", "open", "check", "get", "make", "take", "meet", "book", "set", "add",
    ])
    /// "When I say Peter, I mean James" and "By John I mean Johnny" define a word.
    private static let defining = words(["say", "says", "said", "saying", "by"])
    private static let connectors = words(["to", "or", "and", "through", "by", "until", "till", "x"])
    private static let subjects: Set<String> = ["nsubj", "csubj", "expl"]
    private static let quotes: Set<Unicode.Scalar> = ["\"", "\u{201C}", "\u{201D}", "\u{AB}", "\u{BB}"]

    /// The parser is asked only when one of these is said or a hesitation was heard, in a text that reads as
    /// English.
    static func mentionsCorrection(_ text: String, original: String? = nil) -> Bool {
        let t = Transcript(Array(text.unicodeScalars))
        let cues = correctionMarkers + restartCommands + ambiguousRestartCommands
        let english = t.bare.filter(englishWords.contains).count
        let heard = (original.map { Transcript(Array($0.unicodeScalars)).bare } ?? t.bare).contains(where: hesitates)
        return english > 0 && english * 100 >= t.bare.count * 10
            && (heard || t.bare.indices.contains { i in cues.contains { t.bare[i...].starts(with: $0) } })
    }

    static func correct(
        _ text: String, original: String? = nil, parse: (Words) -> Parse?
    ) -> (text: String, cuts: [Cut]) {
        let said = original.map { Transcript(Array($0.unicodeScalars)) }
        var t = Transcript(Array(text.unicodeScalars))
        var cuts: [Cut] = []
        // A sentence a cut did not touch is asked about again after it.
        var parsed: [String: Parse?] = [:]
        func remembered(_ words: Words) -> Parse? {
            if let known = parsed[words.text] { return known }
            let tree = parse(words)
            parsed[words.text] = .some(tree)
            return tree
        }
        while let edit = firstCorrection(t, heard: said.map { removedHesitations(t, said: $0) } ?? [], remembered)
                ?? firstRestartCommand(t, remembered) {
            cuts.append(edit.cut)
            t = t.cut(edit.first, upto: edit.upto)
        }
        return (String(String.UnicodeScalarView(t.scalars)), cuts)
    }

    /// Where the speaker signalled a correction: the marker words, none when the only sign is a hesitation a
    /// `fillers` table removed, and whether a hesitation was heard there.
    private struct Cue {
        let run: Range<Int>
        let hesitated: Bool
        /// A marker word was said, not only a hesitation.
        let spoken: Bool
    }

    private static func firstCorrection(_ t: Transcript, heard: Set<Int>, _ parse: (Words) -> Parse?) -> Edit? {
        for cue in cues(t, heard: heard) {
            let m = cue.run.lowerBound, e = cue.run.upperBound
            guard m > 0, e < t.words.count, !saysIdiom(t, m), afterStopAllowed(t, cue) else { continue }
            let edit = anchored(t, cue, parse) ?? bare(t, cue, parse)
            if let edit, !quoted(t, edit) { return edit }
        }
        return nil
    }

    private static func cues(_ t: Transcript, heard: Set<Int>) -> [Cue] {
        var found: [Cue] = []
        var m = 0
        while m < t.words.count {
            if let e = markerEnd(t, at: m) {
                let run = m..<e
                let spoken = run.contains { !hesitates(t.bare[$0]) && !openers.contains(t.bare[$0]) }
                let hesitated = heard.contains(m - 1) || run.contains { hesitates(t.bare[$0]) }
                found.append(Cue(run: run, hesitated: hesitated, spoken: spoken))
                m = e
            } else {
                if heard.contains(m - 1) { found.append(Cue(run: m..<m, hesitated: true, spoken: false)) }
                m += 1
            }
        }
        return found
    }

    /// Gaps after word `i` of `t` where the original transcript said a hesitation that an earlier stage removed:
    /// its two neighbours sit side by side now, once in the whole text.
    private static func removedHesitations(_ t: Transcript, said: Transcript) -> Set<Int> {
        let kept = said.bare.indices.filter { !hesitates(said.bare[$0]) }
        var gaps = Set<Int>()
        for (left, right) in zip(kept, kept.dropFirst()) where right > left + 1 {
            let at = t.bare.indices.dropLast().filter { t.bare[$0] == said.bare[left] && t.bare[$0 + 1] == said.bare[right] }
            if at.count == 1 { gaps.insert(at[0]) }
        }
        return gaps
    }

    /// "sorry for the delay", but not "sorry, to Tim".
    private static func saysIdiom(_ t: Transcript, _ m: Int) -> Bool {
        idioms.contains { idiom in
            t.bare[m...].starts(with: idiom) && !(m..<m + idiom.count - 1).contains(where: t.pauses(after:))
        }
    }

    /// Where a run of markers starting at `m` ends: "no, sorry, I mean" is one. Nil when no word follows it.
    private static func markerEnd(_ t: Transcript, at m: Int) -> Int? {
        var end = m
        while end < t.words.count, openers.contains(t.bare[end]) { end += 1 }
        let opened = end
        while end < t.words.count {
            if hesitates(t.bare[end]) {
                end += 1
            } else if let marker = correctionMarkers.first(where: { t.bare[end...].starts(with: $0) }) {
                end += marker.count
            } else {
                break
            }
        }
        guard end > opened, end < t.words.count, !(m..<end).contains(where: t.stops(after:)) else { return nil }
        return end
    }

    /// A stop before the marker is crossed only by a full stop and a spoken marker that does not answer.
    private static func afterStopAllowed(_ t: Transcript, _ cue: Cue) -> Bool {
        let m = cue.run.lowerBound
        guard t.stops(after: m - 1) else { return true }
        let gap = t.scalars[t.words[m - 1].upperBound..<t.words[m].lowerBound]
        let said = cue.run.first { !hesitates(t.bare[$0]) && !openers.contains(t.bare[$0]) }
        return cue.spoken && gap.allSatisfy { !$0.isSentenceEnd || $0 == "." }
            && said.map { at in afterStop.contains { t.bare[at...].starts(with: $0) } } == true
    }

    /// Inside a quotation, or across a quote mark: what someone else said stays as they said it.
    private static func quoted(_ t: Transcript, _ edit: Edit) -> Bool {
        let start = t.words[edit.first].lowerBound, end = t.words[edit.upto].lowerBound
        return t.scalars[..<start].filter(quotes.contains).count % 2 == 1
            || t.scalars[start..<end].contains(where: quotes.contains)
    }

    /// "the rain I mean the sun": the words after the marker repeat the first words of what they replace.
    /// The nearest, longest anchor only: when it fails, a farther one is a weaker reading of the same marker.
    private static func anchored(_ t: Transcript, _ cue: Cue, _ parse: (Words) -> Parse?) -> Edit? {
        let m = cue.run.lowerBound, e = cue.run.upperBound
        for k in stride(from: 3, through: 1, by: -1) where e + k <= t.words.count {
            for extra in 1...3 {
                let a = m - k - extra
                guard a >= 0 else { break }
                guard t.bare[a..<a + k] == t.bare[e..<e + k] else { continue }
                if t.stops(after: m - 1), saidBefore(t, a..<a + k) { return nil }
                return repairs(t, a: a, k: k, cue: cue, parse) ? Edit(first: a, upto: e, cut: .selfCorrection) : nil
            }
        }
        return nil
    }

    /// "…the roses near the fence. No, the tulips." does not say which "the" it takes back.
    private static func saidBefore(_ t: Transcript, _ anchor: Range<Int>) -> Bool {
        (t.sentenceStart(anchor.lowerBound)..<anchor.lowerBound).contains { t.bare[$0...].starts(with: t.bare[anchor]) }
    }

    private static func repairs(_ t: Transcript, a: Int, k: Int, cue: Cue, _ parse: (Words) -> Parse?) -> Bool {
        let marker = cue.run, m = marker.lowerBound, e = marker.upperBound
        let last = t.bare[m - 1]
        // The repair says something the words it replaces did not: "There is no way, no, there is no way".
        let taken = Set(t.bare[a..<m])
        let repair = e + k..<max(e + k, min(t.sentenceEnd(e) + 1, e + (m - a) + 2))
        guard !(a..<m - 1).contains(where: t.stops(after:)),
              // "tea or no tea", "I'm sorry I'm late": the marker belongs to the sentence.
              !closingWords.contains(last), !last.contains("'"), !last.contains("\u{2019}"),
              !(a..<a + k).contains(where: { isNumber(t, $0) }),
              !repair.isEmpty, repair.contains(where: { !taken.contains(t.bare[$0]) }),
              !defines(t, before: a, marker: marker),
              let tree = Tree(t, from: t.sentenceStart(a), to: t.sentenceEnd(e), parse: parse),
              isMarker(tree, t, cue),
              let replaced = tree.phrase(t, a..<m), let first = tree.node(t, e), let anchor = tree.node(t, a),
              !tree.splitsNumber(tree.nodes(t, a..<m))
        else { return false }
        // "Wait, the build is broken, wait, the tests pass": a whole clause needs more than "the" to anchor it.
        if k < 2, tree.nodes(t, a + k..<m).contains(where: { [.verb, .aux].contains(tree.tag($0)) }) { return false }
        let chain = tree.chain(from: first)
        // "into main, I mean into develop": one preposition, two objects.
        let preposition = tree.relation(anchor) == "case" && tree.relation(first) == "case"
        guard let parallel = chain.first(where: { sameKind(tree.tag($0), tree.tag(replaced)) })
                ?? (preposition ? chain.dropFirst().first : nil)
        else { return false }
        // With only a hesitation to go on, "to Paris um to Rome and to Berlin" is a list said slowly.
        if !cue.spoken, tree.relation(parallel) == "conj"
            || (e + k..<max(e + k, t.sentenceEnd(e) + 1)).contains(where: { t.bare[$0...].starts(with: t.bare[a..<a + k]) }) {
            return false
        }
        // "Go with the plan, no, the plan has a flaw": the repair starts a clause of its own. After "actually"
        // or "I mean" only a subject may be replaced by one: "I love New York, actually, New Jersey is better".
        let subjectLike = explains(t, marker) ? subjects : subjects.union(["dislocated", "reparandum"])
        if subjects.contains(tree.relation(parallel)) {
            // A preposition left behind ("in the docs folder, sorry, the docs folder is empty") cannot take a
            // subject. With any other repair it takes the new object.
            if !subjectLike.contains(tree.relation(replaced)) || tree.orphans(t, a..<m, from: t.sentenceStart(a)) {
                return false
            }
        }
        return !restatesClause(tree, t, a..<m, replaced, marker: marker)
    }

    /// "with Peter I mean James": a name or a number, then another of the same kind that ends the clause. After
    /// a full stop, "Let's make the road cleaner. I mean greener." swaps any noun or adjective, when the repair
    /// is all the sentence says.
    /// "with Peter I mean James", "some pork, I mean chicken": one name, number, noun or adjective for another
    /// of the same kind, ending the clause. A hesitation alone swaps only a name: "with Peter uh James".
    private static func bare(_ t: Transcript, _ cue: Cue, _ parse: (Words) -> Parse?) -> Edit? {
        let m = cue.run.lowerBound, e = cue.run.upperBound
        let start = t.sentenceStart(m - 1)
        let crossing = t.stops(after: m - 1)
        // A hesitation inside a number is the number said slowly: "two hundred uh 50".
        let kinds: [UPOS] = cue.spoken ? [.propn, .num, .noun, .adj] : [.propn]
        // "at three, I mean three sharp" swaps nothing.
        guard t.bare[m - 1] != t.bare[e],
              let tree = Tree(t, from: start, to: t.sentenceEnd(e), parse: parse),
              let x = tree.node(t, m - 1), let y = tree.node(t, e),
              tree.tag(x) == tree.tag(y), kinds.contains(tree.tag(x)),
              isMarker(tree, t, cue)
        else { return nil }
        let kind = tree.tag(x)
        let same = { (i: Int) in tree.node(t, i).map { tree.tag($0) == kind } ?? false }
        var from = m - 1
        while from > start, !t.pauses(after: from - 1), same(from - 1) { from -= 1 }
        var to = e
        while to + 1 < t.words.count, !t.pauses(after: to), same(to + 1) { to += 1 }
        // A verb after the repair makes it a subject: "I told Peter, I mean, John was right".
        let next = to + 1 < t.words.count && !t.pauses(after: to) ? tree.node(t, to + 1) : nil
        // "The score was 2 to 1, no, 3 to 1": the number is the end of a range.
        let ranged = from >= 2 && connectors.contains(t.bare[from - 1]) && (isNumber(t, from - 2)
            || tree.node(t, from - 2).map { tree.tag($0) == .num } == true)
        // "add milk to the list umm no oat milk" takes back the milk, not the list.
        let echoed = (t.sentenceStart(from)..<from).contains { (e...to).map { t.bare[$0] }.contains(t.bare[$0]) }
        // "Peter um James and Mary": a list said slowly, when nothing but the hesitation marks it.
        let listed = !cue.spoken && from > 0 && (conjunctions.contains(t.bare[from - 1]) || t.pauses(after: from - 1)
            || (to + 1 < t.words.count && conjunctions.contains(t.bare[to + 1])))
        guard from > start, !listed, !echoed, next.map({ ![.verb, .aux].contains(tree.tag($0)) }) ?? true, !isNumber(t, from - 1),
              !ranged, !defines(t, before: from, marker: m..<e), !crossing || to + 1 == t.words.count || t.stops(after: to),
              !subjects.contains(tree.relation(x)),
              !subjects.contains(tree.relation(y)),
              // "at eight, or rather one if you feel fine" is a second option.
              !(tree.relation(y) == "conj" && tree.children(of: y).contains { tree.relation($0) == "cc" })
        else { return nil }
        return Edit(first: from, upto: e, cut: .selfCorrection)
    }

    /// "When I say Peter, I mean James", "By John I mean Johnny": "I mean" gives a meaning, it corrects nothing.
    private static func defines(_ t: Transcript, before first: Int, marker: Range<Int>) -> Bool {
        let mean = words(["mean", "meant"])
        guard marker.contains(where: { mean.contains(t.bare[$0]) }) else { return false }
        return first > 0 && defining.contains(t.bare[first - 1])
    }

    /// "He is not rude, I mean he is just tired": a whole clause again, after a marker that also explains.
    /// After "no" or "sorry" the same shape is a correction.
    private static func restatesClause(
        _ tree: Tree, _ t: Transcript, _ span: Range<Int>, _ replaced: Int, marker: Range<Int>
    ) -> Bool {
        explains(t, marker) && tree.nodes(t, span).contains {
            tree.head($0) == replaced && subjects.contains(tree.relation($0))
        }
    }

    /// "I mean", "actually" and "or rather" also introduce an explanation; "no" and "sorry" only correct.
    private static func explains(_ t: Transcript, _ marker: Range<Int>) -> Bool {
        marker.contains { explaining.contains(t.bare[$0]) }
    }

    private static let explaining = words(["mean", "actually", "rather"])

    /// "no" as a discourse word, not a determiner ("no way") or what a verb says ("He said no"); "I mean"
    /// with no "that" or wh-word of its own ("what I mean is").
    private static func isMarker(_ tree: Tree, _ t: Transcript, _ cue: Cue) -> Bool {
        let run = cue.run
        let repair = run.upperBound < t.words.count ? tree.node(t, run.upperBound) ?? Int.max : Int.max
        return run.allSatisfy { i in
            guard let n = tree.node(t, i) else { return false }
            // A correction's "no" hangs on the repair after it. "He said no" and "voted no" hang it on the verb.
            if t.bare[i] == Array("no".unicodeScalars), let up = tree.head(n), up < n { return false }
            let word = String(String.UnicodeScalarView(t.bare[i]))
            if tree.tag(n) == .intj || ["discourse", "reparandum"].contains(tree.relation(n)) { return true }
            switch word {
            case "no":
                // "no wait" parses as a determiner and its noun. Before "some" or "the", "no" cannot be one, and
                // after a hesitation it is the speaker taking something back: "pork. Uh no chicken".
                return cue.hesitated || (i + 1 < t.words.count && determiners.contains(t.bare[i + 1]))
                    || (i + 1 < run.upperBound && t.bare[i + 1] == Array("wait".unicodeScalars))
            case "sorry":
                return false
            case "wait":
                // On its own: nothing hangs on it but the punctuation, its "no" and the misattached repair.
                return tree.children(of: n).allSatisfy {
                    $0 >= repair || tree.tag($0) == .punct || tree.words[$0].string.lowercased() == "no"
                }
            case "mean", "meant":
                return [.verb, .aux].contains(tree.tag(n)) && !tree.children(of: n).contains {
                    tree.relation($0) == "mark" || Tree.whWords.contains(tree.words[$0].string.lowercased())
                }
            default:
                return true
            }
        }
    }

    /// A function word cannot end what a marker takes back. An object pronoun can: "to him, no, to her".
    private static let closingWords = functionWords.subtracting(words(["it", "him", "her", "them", "me", "us", "you"]))

    private static func sameKind(_ a: UPOS, _ b: UPOS) -> Bool {
        a == b || ([.noun, .propn].contains(a) && [.noun, .propn].contains(b))
    }

    private static func isNumber(_ t: Transcript, _ i: Int) -> Bool {
        t.words.indices.contains(i) && (isDigits(t.bare[i]) || numberWords.contains(t.bare[i]))
    }

    private static func firstRestartCommand(_ t: Transcript, _ parse: (Words) -> Parse?) -> Edit? {
        for c in t.words.indices.dropFirst() {
            let strong = restartCommands.filter { t.bare[c...].starts(with: $0) }.map(\.count).max() ?? 0
            let weak = ambiguousRestartCommands.filter { t.bare[c...].starts(with: $0) }.map(\.count).max() ?? 0
            let d = c + max(strong, weak)
            guard d > c, d < t.words.count, t.pauses(after: c - 1), t.pauses(after: d - 1),
                  !(c..<d - 1).contains(where: t.pauses(after:))
            else { continue }
            var s = c - 1
            while s > 0, !t.stops(after: s - 1) { s -= 1 }
            let dropped = s..<c
            guard !dropped.contains(where: { commandWords.contains(t.bare[$0]) }) else { continue }
            let afterStop = t.stops(after: c - 1)
            if strong == d - c {
                guard t.bare[s] == t.bare[d] || afterStop else { continue }
            } else {
                guard afterStop, saysAgain(t, dropped, from: d) else { continue }
            }
            guard let tree = Tree(t, from: s, to: t.sentenceEnd(d), parse: parse) else { continue }
            let command = tree.nodes(t, c..<d)
            // "let me restart, the server" is still the server.
            let takes = command.contains { w in
                tree.children(of: w).contains {
                    !command.contains($0) && ["obj", "iobj", "obl", "xcomp", "ccomp"].contains(tree.relation($0))
                }
            }
            // "The server is down. Let me restart. The server is up." restarts the server.
            let thing = strong != d - c && tree.nodes(t, dropped).contains {
                subjects.contains(tree.relation($0)) && [.noun, .propn].contains(tree.tag($0))
            }
            let edit = Edit(first: s, upto: d, cut: .restartCommand)
            if !takes, !thing, !quoted(t, edit) { return edit }
        }
        return nil
    }

    /// The sentence after the command says the dropped one again with one or two words changed: "Let's make
    /// the road cleaner. Let me restart. Let's make the road greener."
    private static func saysAgain(_ t: Transcript, _ dropped: Range<Int>, from next: Int) -> Bool {
        let again = next..<t.sentenceEnd(next) + 1
        guard again.count == dropped.count, dropped.count >= 3 else { return false }
        let pairs = zip(t.bare[dropped], t.bare[again])
        let shared = pairs.prefix { $0 == $1 }.count
        return shared >= 3 && pairs.filter { $0 != $1 }.count <= 2
    }
}

/// One parse of whole sentences of a transcript, read by transcript word.
private struct Tree {
    let words: [Words.Word]
    let parse: [Parse.Word]
    /// Where the parsed stretch starts in the transcript, in scalars.
    let base: Int
    /// UTF-16 offset of each scalar of the stretch, and one past the end.
    let utf16: [Int]

    init?(_ t: Transcript, from first: Int, to last: Int, parse: (Words) -> Parse?) {
        let lo = t.words[first].lowerBound
        var hi = last + 1 < t.words.count ? t.words[last + 1].lowerBound : t.scalars.count
        while hi > lo, t.scalars[hi - 1].isSpace { hi -= 1 }
        let stretch = Array(t.scalars[lo..<hi])
        guard let words = WordSplit.english(String(String.UnicodeScalarView(stretch))),
              let tree = parse(words), tree.words.count == words.all.count
        else { return nil }
        self.words = words.all
        self.parse = tree.words
        base = lo
        var utf16 = [0]
        for scalar in stretch { utf16.append(utf16[utf16.count - 1] + scalar.utf16.count) }
        self.utf16 = utf16
    }

    /// The parse words that start inside transcript words `range`. "I'm" is two.
    func nodes(_ t: Transcript, _ range: Range<Int>) -> [Int] {
        guard let first = range.first, let last = range.last,
              t.words[first].lowerBound >= base, t.words[last].upperBound - base < utf16.count
        else { return [] }
        let a = utf16[t.words[first].lowerBound - base], b = utf16[t.words[last].upperBound - base]
        return words.indices.filter { a <= words[$0].utf16.lowerBound && words[$0].utf16.lowerBound < b }
    }

    func node(_ t: Transcript, _ i: Int) -> Int? { nodes(t, i..<i + 1).first }

    func tag(_ i: Int) -> UPOS { parse[i].tag }

    /// The UD relation without its subtype: `nsubj:pass` is `nsubj`.
    func relation(_ i: Int) -> String { String(parse[i].label.prefix { $0 != ":" }) }

    func head(_ i: Int) -> Int? { parse[i].head > 0 ? parse[i].head - 1 : nil }

    func children(of i: Int) -> [Int] { parse.indices.filter { parse[$0].head == i + 1 } }

    /// The one word of transcript words `range` whose head is outside them, or nil when they are not one
    /// phrase.
    func phrase(_ t: Transcript, _ range: Range<Int>) -> Int? {
        let span = nodes(t, range)
        let tops = span.filter { word in head(word).map { !span.contains($0) } ?? true }
        return tops.count == 1 ? tops[0] : nil
    }

    /// `word` and its heads, while they stay at or after it: the phrase a repair word heads.
    func chain(from word: Int) -> [Int] {
        var chain = [word]
        while chain.count <= parse.count, let up = head(chain[chain.count - 1]), up >= word { chain.append(up) }
        return chain
    }

    /// A preposition or modifier said before transcript words `range` that belongs to their noun: cutting them
    /// strands it. "in the docs folder, sorry, the docs folder is empty" strands "in".
    func orphans(_ t: Transcript, _ range: Range<Int>, from start: Int) -> Bool {
        let span = Set(nodes(t, range))
        let modifiers: Set<String> = ["case", "det", "nummod", "amod", "compound", "nmod"]
        return nodes(t, start..<range.lowerBound).contains { word in
            modifiers.contains(relation(word)) && head(word).map(span.contains) == true
        }
    }

    /// A number link from inside `span` to outside it: cutting there splits "two hundred".
    func splitsNumber(_ span: [Int]) -> Bool {
        let links: Set<String> = ["nummod", "compound", "flat", "fixed"]
        return parse.indices.contains { word in
            guard let up = head(word), span.contains(word) != span.contains(up), links.contains(relation(word))
            else { return false }
            return tag(word) == .num || tag(up) == .num
        }
    }

    static let whWords: Set<String> = [
        "what", "who", "whom", "whose", "which", "where", "when", "why", "how",
        "whatever", "whoever", "whichever", "wherever", "whenever", "however",
    ]
}
