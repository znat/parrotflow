import Foundation

/// The words the syrinx parser reads, and the windows a long text is parsed in.
///
/// Ports of `cue_rule.parse.tokenize` and `cue_replay.replay.windows`. One
/// splitter for every language: the language picks the clitic table, nothing
/// else. Offsets count `Unicode.Scalar`s, as Python indexes code points.
enum WordSplit {

    struct Word: Equatable {
        let text: String
        let scalars: Range<Int>
    }

    /// Punctuation split off both ends of each `\S+` run, then one clitic split.
    static func words(_ scalars: [Unicode.Scalar], in range: Range<Int>, language: String) -> [Word] {
        let split = language == "fr" ? elision : clitic
        var out: [Word] = []
        var i = range.lowerBound
        while i < range.upperBound {
            if isSpace(scalars[i]) { i += 1; continue }
            var e = i
            while e < range.upperBound && !isSpace(scalars[e]) { e += 1 }
            let next = e
            var s = i
            while s < e && !isAlnum(scalars[s]) {
                out.append(word(scalars, s ..< s + 1))
                s += 1
            }
            var tail: [Word] = []
            while e > s && !isAlnum(scalars[e - 1]) {
                tail.insert(word(scalars, e - 1 ..< e), at: 0)
                e -= 1
            }
            if s < e {
                if let k = split(scalars, s ..< e) {
                    out.append(word(scalars, s ..< k))
                    out.append(word(scalars, k ..< e))
                } else {
                    out.append(word(scalars, s ..< e))
                }
            }
            out += tail
            i = next
        }
        return out
    }

    /// Runs of whole sentences that each fit one parse. A sentence too long on
    /// its own is split at commas, then into 60-word runs.
    static func windows(_ scalars: [Unicode.Scalar], language: String, fits: ([String]) -> Bool) -> [Range<Int>] {
        func sizeOK(_ range: Range<Int>) -> Bool {
            fits(words(scalars, in: range, language: language).map(\.text))
        }
        var units: [Range<Int>] = []
        for piece in pieces(scalars, in: 0 ..< scalars.count, after: [".", "?", "!", "…"]) {
            if sizeOK(piece) { units.append(piece); continue }
            for part in pieces(scalars, in: piece, after: [","]) {
                if sizeOK(part) { units.append(part); continue }
                let found = runs(scalars, in: part)
                for k in stride(from: 0, to: found.count, by: 60) {
                    units.append(found[k].lowerBound ..< found[min(k + 60, found.count) - 1].upperBound)
                }
            }
        }
        var out: [Range<Int>] = []
        for unit in units {
            if let last = out.last, sizeOK(last.lowerBound ..< unit.upperBound) {
                out[out.count - 1] = last.lowerBound ..< unit.upperBound
            } else {
                out.append(unit)
            }
        }
        return out
    }

    /// Splits at each whitespace run whose first scalar follows one of `after`.
    private static func pieces(_ scalars: [Unicode.Scalar], in range: Range<Int>, after: Set<Unicode.Scalar>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var at = range.lowerBound
        var i = range.lowerBound + 1
        while i < range.upperBound {
            guard isSpace(scalars[i]), after.contains(scalars[i - 1]) else { i += 1; continue }
            var j = i
            while j < range.upperBound && isSpace(scalars[j]) { j += 1 }
            out.append(at ..< i)
            at = j
            i = j + 1
        }
        out.append(at ..< range.upperBound)
        return out.filter { !$0.isEmpty }
    }

    private static func runs(_ scalars: [Unicode.Scalar], in range: Range<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = range.lowerBound
        while i < range.upperBound {
            if isSpace(scalars[i]) { i += 1; continue }
            var j = i
            while j < range.upperBound && !isSpace(scalars[j]) { j += 1 }
            out.append(i ..< j)
            i = j
        }
        return out
    }

    private static let clitics = ["n't", "n’t", "'m", "'ll", "'s", "'re", "'ve", "'d", "’m", "’ll", "’s", "’re", "’ve", "’d"]
        .map { Array($0.unicodeScalars) }

    /// `(?i)^(.+?)(n't|'m|…)$`: where the shortest head leaves a clitic.
    private static func clitic(_ scalars: [Unicode.Scalar], _ range: Range<Int>) -> Int? {
        (range.lowerBound + 1 ..< range.upperBound).first { k in
            clitics.contains { $0.count == range.upperBound - k && zip($0, scalars[k ..< range.upperBound]).allSatisfy { $0 == fold($1) } }
        }
    }

    private static let apostrophes: Set<Unicode.Scalar> = ["'", "’"]
    private static let elided: Set<Unicode.Scalar> = ["c", "d", "j", "l", "m", "n", "s", "t"]

    /// `(?i)^(qu'|[cdjlmnst]')(.+)$`, either apostrophe.
    private static func elision(_ scalars: [Unicode.Scalar], _ range: Range<Int>) -> Int? {
        let s = range.lowerBound, count = range.count
        if count >= 4, fold(scalars[s]) == "q", fold(scalars[s + 1]) == "u", apostrophes.contains(scalars[s + 2]) {
            return s + 3
        }
        if count >= 3, elided.contains(fold(scalars[s])), apostrophes.contains(scalars[s + 1]) { return s + 2 }
        return nil
    }

    /// Python `re.IGNORECASE` on the letters above: ASCII, and `ſ` matches `s`.
    private static func fold(_ c: Unicode.Scalar) -> Unicode.Scalar {
        if ("A"..."Z").contains(c) { return Unicode.Scalar(UInt8(c.value + 32)) }
        return c == "\u{17F}" ? "s" : c
    }

    private static func word(_ scalars: [Unicode.Scalar], _ range: Range<Int>) -> Word {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[range])
        return Word(text: String(view), scalars: range)
    }

    // Python 3.10 is Unicode 13.0; later scalars are unassigned there.
    private static func inPython(_ c: Unicode.Scalar) -> Bool { (c.properties.age?.major ?? .max) <= 13 }

    static func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace || ("\u{1C}"..."\u{1F}").contains(c) }

    static func isAlnum(_ c: Unicode.Scalar) -> Bool {
        guard inPython(c) else { return false }
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return c.properties.numericType != nil
        }
    }
}
