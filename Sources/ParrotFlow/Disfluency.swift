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

    struct Cleaned {
        var text: String
        /// One entry per cut, string passes first, then the markers.
        var applied: [String]
        var declined: String
    }

    /// Every rule, in order. The marker rule runs last: by then "I mean I mean" is one marker. `parser` is
    /// asked only for English text that holds a marker, and nil means it is not loaded yet.
    static func clean(_ text: String, language: String, parser: () async -> Parser?) async -> Cleaned {
        let done = collapse(text)
        var cleaned = Cleaned(text: done.text, applied: done.cuts.map(\.rawValue), declined: "")
        guard language == "en", mentionsMarker(done.text) else { return cleaned }
        guard let parser = await parser() else {
            cleaned.declined = "word fillers: the parser is not ready"
            return cleaned
        }
        let markers = resolveMarkers(done.text) { parser.parse(words: $0, language: "en") }
        cleaned.text = markers.text
        cleaned.applied += markers.cut.map(\.rawValue)
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

    /// Python's `any(marker_pattern(p).search(text) for p in ("i mean", "you know", "like"))`.
    static func mentionsMarker(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return Marker.allCases.contains { marker in
            scalars.indices.contains { matchEnd(marker.scalars, in: scalars, at: $0) != nil }
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

    /// What `re.I` matches beyond ASCII case, for the letters in the markers (exhaustive scan, Python 3.10).
    private static let extraFolds: [Unicode.Scalar: Set<Unicode.Scalar>] = [
        "i": ["\u{130}", "\u{131}"],
        "k": ["\u{212A}"],
    ]

    /// `\b` + marker + `\b` with `re.I`, starting at `start`. A space in the marker is `\s+`. Returns where
    /// the match ends.
    fileprivate static func matchEnd(
        _ marker: [Unicode.Scalar], in text: [Unicode.Scalar], at start: Int
    ) -> Int? {
        if start > 0, text[start - 1].isWord { return nil }
        var at = start
        for letter in marker {
            if letter == " " {
                let from = at
                while at < text.count, text[at].isSpace { at += 1 }
                if at == from { return nil }
            } else {
                guard at < text.count else { return nil }
                let scalar = text[at]
                guard scalar == letter || scalar.value == letter.value - 0x20
                        || extraFolds[letter]?.contains(scalar) == true
                else { return nil }
                at += 1
            }
        }
        return at == text.count || !text[at].isWord ? at : nil
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

// MARK: - Word fillers

/// The marker rule of `disfluency.py` (`resolve`, `wants_cut`, `cut`), judged on a parrot-syrinx tree instead
/// of spaCy. spaCy's labels are mapped to their UD twins, and lemmas are replaced by surface forms plus UPOS
/// VERB or AUX. Offsets are scalars, as in Python, until a sentence meets its parse.
extension Disfluency {

    /// In Python's `resolve` order.
    enum Marker: String, CaseIterable {
        case iMean = "i mean"
        case youKnow = "you know"
        case like

        var scalars: [Unicode.Scalar] { Array(rawValue.unicodeScalars) }

        /// The marker's own verb. `like` has none, so it goes on its tag.
        var verbForms: Set<String>? {
            switch self {
            case .iMean: ["mean", "means", "meant"]
            case .youKnow: ["know", "knows", "knew", "knowing"]
            case .like: nil
            }
        }
    }

    /// Judged first, then cut a sentence at a time: a cut changes the parse of its own sentence. Sentences are
    /// replaced from the right because a cut moves every offset after it. A sentence the splitter or the
    /// parser abstains on keeps its markers.
    static func resolveMarkers(_ text: String, parse: (Words) -> Parse?) -> (text: String, cut: [Marker]) {
        var scalars = Array(text.unicodeScalars)
        var trees: [Int: Tree?] = [:]
        var cuts: [Int: (sentence: Range<Int>, spans: [(Range<Int>, Marker)])] = [:]
        for marker in Marker.allCases {
            var at = 0
            while at < scalars.count {
                guard let end = matchEnd(marker.scalars, in: scalars, at: at) else {
                    at += 1
                    continue
                }
                let sentence = sentenceOf(scalars, at, end)
                let span = at - sentence.lowerBound ..< end - sentence.lowerBound
                let tree: Tree?
                if let parsed = trees[sentence.lowerBound] {
                    tree = parsed
                } else {
                    tree = Tree(Array(scalars[sentence]), parse: parse)
                    trees[sentence.lowerBound] = .some(tree)
                }
                if let tree, tree.wantsCut(marker, at: span) {
                    cuts[sentence.lowerBound, default: (sentence, [])].spans.append((span, marker))
                }
                at = end
            }
        }
        var said: [Marker] = []
        for offset in cuts.keys.sorted(by: >) {
            guard let (sentence, spans) = cuts[offset] else { continue }
            scalars.replaceSubrange(sentence, with: cut(Array(scalars[sentence]), spans.map(\.0)))
            said += spans.sorted {
                ($0.0.lowerBound, $0.0.upperBound, $0.1.rawValue) < ($1.0.lowerBound, $1.0.upperBound, $1.1.rawValue)
            }.map(\.1)
        }
        return (String(String.UnicodeScalarView(scalars)), said)
    }

    /// Python's `sentence_of`: from after the last `.?!` before the marker to the first one after it. No strip:
    /// stripping moved every offset and made the cuts eat a letter, "So like a generation" -> "So la generation".
    private static func sentenceOf(_ text: [Unicode.Scalar], _ at: Int, _ end: Int) -> Range<Int> {
        let stops: Set<Unicode.Scalar> = [".", "?", "!"]
        let lo = (text[..<at].lastIndex(where: stops.contains) ?? -1) + 1
        let hi = text[end...].firstIndex(where: stops.contains).map { $0 + 1 } ?? text.count
        return lo ..< hi
    }

    /// Python's `cut`: every marker in one sentence, right to left, each with one adjacent comma. Without the
    /// comma, "And you know, the comments should be" left "And, the comments should be", 8 of 186 cuts. The
    /// sentence keeps its leading space, which is the gap after the previous full stop, and its capital when
    /// the first word went: "I mean the hesitations part" -> "The hesitations part".
    private static func cut(_ sentence: [Unicode.Scalar], _ spans: [Range<Int>]) -> [Unicode.Scalar] {
        let lead = sentence.prefix { $0.isSpace }
        let capitalised = sentence.dropFirst(lead.count).first?.properties.isUppercase == true
        var sentence = sentence
        for span in spans.sorted(by: { ($0.lowerBound, $0.upperBound) > ($1.lowerBound, $1.upperBound) }) {
            var head = Array(sentence[..<span.lowerBound])
            var tail = Array(sentence[span.upperBound...])
            let afterSpace = tail.prefix { $0.isSpace }.count
            let beforeSpace = head.reversed().prefix { $0.isSpace }.count
            if afterSpace < tail.count, [",", ";"].contains(tail[afterSpace]) {
                tail.removeFirst(afterSpace + 1)
            } else if beforeSpace < head.count, [",", ";"].contains(head[head.count - beforeSpace - 1]) {
                head.removeLast(beforeSpace + 1)
            }
            if head.contains(where: { !$0.isSpace }), tail.contains(where: { !$0.isSpace }),
               head.last?.isSpace == false, tail.first?.isSpace == false {
                head.append(" ")
            }
            sentence = head + tail
        }
        var body = tightened(sentence)
        body.removeFirst(body.prefix { $0.isSpace }.count)
        if capitalised, let first = body.first, first.properties.isLowercase {
            body.replaceSubrange(0 ..< 1, with: first.properties.uppercaseMapping.unicodeScalars)
        }
        return Array(lead) + body
    }

    /// `re.sub(r"\s+([,.;?!])", r"\1", re.sub(r"[ \t]{2,}", " ", s))`.
    private static func tightened(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var spaced: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            var j = i
            while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
            if j - i >= 2 {
                spaced.append(" ")
                i = j
            } else {
                spaced.append(s[i])
                i += 1
            }
        }
        var out: [Unicode.Scalar] = []
        i = 0
        while i < spaced.count {
            var j = i
            while j < spaced.count, spaced[j].isSpace { j += 1 }
            if j > i, j < spaced.count, [",", ".", ";", "?", "!"].contains(spaced[j]) {
                i = j
                continue
            }
            out.append(contentsOf: spaced[i ..< max(j, i + 1)])
            i = max(j, i + 1)
        }
        return out
    }
}

/// One sentence, its words and their parse, read in UTF-16 like `Words`.
private struct Tree {
    let words: [Words.Word]
    let parse: [Parse.Word]
    /// UTF-16 offset of each scalar of the sentence, and one past the end.
    let utf16: [Int]

    init?(_ sentence: [Unicode.Scalar], parse: (Words) -> Parse?) {
        guard let words = WordSplit.english(String(String.UnicodeScalarView(sentence))),
              let tree = parse(words), tree.words.count == words.all.count
        else { return nil }
        self.words = words.all
        self.parse = tree.words
        var utf16 = [0]
        for scalar in sentence { utf16.append(utf16[utf16.count - 1] + scalar.utf16.count) }
        self.utf16 = utf16
    }

    /// spaCy's sets in `disfluency.py`, through `LABEL_MAP` in `training/syntax-parser/marker_rule_ud.py`.
    /// `attr` has no UD twin.
    /// The marker verb's own object: if it has one, the marker is doing work.
    private static let object: Set<String> = ["ccomp", "obj", "xcomp"]
    /// The marker is itself an argument: "we'll let you know".
    private static let argument: Set<String> = ["acl", "advcl", "ccomp", "conj", "csubj", "nmod", "obj", "obl", "xcomp"]
    /// A verb ("I like it"), a preposition ("like a cat") and a subordinator ("like I said") all stay.
    private static let likeKeeps: Set<UPOS> = [.verb, .aux, .adp, .sconj]

    func wantsCut(_ marker: Disfluency.Marker, at scalars: Range<Int>) -> Bool {
        let a = utf16[scalars.lowerBound], b = utf16[scalars.upperBound]
        guard let forms = marker.verbForms else {
            guard let like = words.firstIndex(where: { $0.utf16.lowerBound <= a && a < $0.utf16.upperBound })
            else { return false }
            return !Self.likeKeeps.contains(parse[like].tag) || approximates(like)
        }
        // The marker's own verb, not the sentence's first one: "You know, do you know who owns this account?"
        // holds a filler and a question, and matching on the form alone cut both.
        guard let verb = words.indices.first(where: {
            a <= words[$0].utf16.lowerBound && words[$0].utf16.lowerBound < b
                && forms.contains(words[$0].string.lowercased()) && [.verb, .aux].contains(parse[$0].tag)
        }) else { return false }
        let objects = children(of: verb).filter { Self.object.contains(parse[$0].label) }
        if !objects.isEmpty, !(words.first?.utf16.lowerBound == a && objects.allSatisfy(isPlainClause)) {
            return false
        }
        if Self.argument.contains(parse[verb].label) { return false }
        return !substitution(a, b)
    }

    private func children(of index: Int) -> [Int] {
        parse.indices.filter { parse[$0].head == index + 1 }
    }

    /// A sentence-initial "I mean" read as a verb whose object is a clause with its own subject, and no
    /// "that" or wh-word: "I mean you should try". "I mean that we need tests", "I mean who cares" and
    /// "I mean it" keep it.
    private func isPlainClause(_ head: Int) -> Bool {
        let below = children(of: head)
        return below.contains { parse[$0].label == "nsubj" }
            && !below.contains { parse[$0].label == "mark" }
            && !([head] + below).contains { Self.whWords.contains(words[$0].string.lowercased()) }
    }

    private static let whWords: Set<String> = [
        "what", "who", "whom", "whose", "which", "where", "when", "why", "how",
        "whatever", "whoever", "whichever", "wherever", "whenever", "however",
    ]

    /// `like` as an approximator, a preposition right before a number: "it took like three hours". Not
    /// after a verb of seeming or a -thing pronoun, where it compares: "it felt like one long day",
    /// "something like five". Not as a subordinator: "it looks like two of them failed".
    private func approximates(_ like: Int) -> Bool {
        guard parse[like].label == "case", parse.indices.contains(like + 1),
              parse[like + 1].tag == .num || words[like + 1].string.allSatisfy(\.isNumber)
        else { return false }
        return like == 0 || !Self.comparing.contains(words[like - 1].string.lowercased())
    }

    private static let comparing: Set<String> = [
        "look", "looks", "looked", "looking", "feel", "feels", "felt", "feeling",
        "seem", "seems", "seemed", "seeming", "sound", "sounds", "sounded", "sounding",
        "taste", "tastes", "tasted", "smell", "smells", "smelled", "smelt",
        "something", "anything", "nothing", "everything",
    ]

    /// A noun on both sides is a self-correction, not a filler: "I was with James I mean Peter, sorry".
    /// Deleting the marker leaves both names, which is worse than leaving the sentence alone.
    private func substitution(_ a: Int, _ b: Int) -> Bool {
        let outside = words.indices.filter {
            parse[$0].tag != .punct && (words[$0].utf16.upperBound <= a || words[$0].utf16.lowerBound >= b)
        }
        guard let before = outside.last(where: { words[$0].utf16.lowerBound < a }),
              let after = outside.first(where: { words[$0].utf16.lowerBound >= b })
        else { return false }
        return [.noun, .propn].contains(parse[before].tag) && [.noun, .propn].contains(parse[after].tag)
    }
}
