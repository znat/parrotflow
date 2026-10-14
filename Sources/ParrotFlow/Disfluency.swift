/// The string rules of `built-in/transforms/disfluency/disfluency.py`, ported scalar for scalar. Python
/// offsets are code points, so every index here counts `Unicode.Scalar`s, and tokens are compared as scalar
/// arrays: Swift's `String ==` is canonical equivalence, Python's is code points.
enum Disfluency {
    /// What `applied` names, one per cut. Raw values are Python's strings.
    enum Cut: String {
        case falseStart = "false start"
        case phraseRestarted = "phrase restarted"
        case wordRestarted = "word restarted"
        case phraseSaidTwice = "phrase said twice"
        case wordSaidTwice = "word said twice"
    }

    struct Outcome {
        var text: String
        /// One entry per cut, in the order made, repeats kept (Python's `applied` list).
        var cuts: [Cut]
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

    /// Python's `any(marker_pattern(p).search(text) for p in ("i mean", "you know", "like"))`.
    static func mentionsMarker(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return markers.contains { marker in
            scalars.indices.contains { matches(marker, in: scalars, at: $0) }
        }
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

    /// Longest repeated phrase considered; longer than 3 words is unseen in the archive.
    private static let maxPhrase = 4

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
            (pair.n == 1 && pair.raw.allSatisfy { isLetter($0) && $0.first?.properties.isUppercase == true })
                || (pair.n > 1 && pair.raw.allSatisfy(isLetter))
        },
        // A lone lower-case letter is only a spelling if it sits among letters.
        { pair in
            pair.n == 1 && pair.raw.allSatisfy(isLetter) && pair.neighbours.contains(where: isLetter)
        },
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

    private static let markers = ["i mean", "you know", "like"].map { Array($0.unicodeScalars) }

    /// What `re.I` matches beyond ASCII case, for the letters in the markers (exhaustive scan, Python 3.10).
    private static let extraFolds: [Unicode.Scalar: Set<Unicode.Scalar>] = [
        "i": ["\u{130}", "\u{131}"],
        "k": ["\u{212A}"],
    ]

    /// `\b` + marker + `\b` with `re.I`, starting at `start`. A space in the marker is `\s+`.
    private static func matches(
        _ marker: [Unicode.Scalar], in text: [Unicode.Scalar], at start: Int
    ) -> Bool {
        if start > 0, text[start - 1].isWord { return false }
        var at = start
        for letter in marker {
            if letter == " " {
                let from = at
                while at < text.count, text[at].isSpace { at += 1 }
                if at == from { return false }
            } else {
                guard at < text.count else { return false }
                let scalar = text[at]
                guard scalar == letter || scalar.value == letter.value - 0x20
                        || extraFolds[letter]?.contains(scalar) == true
                else { return false }
                at += 1
            }
        }
        return at == text.count || !text[at].isWord
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
