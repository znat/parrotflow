import Foundation

/// A port of the Python `ud_split_en.split`.
///
/// Every test is on `Unicode.Scalar`: `String` equality is canonical, so
/// "\u{212A}" == "K".
enum WordSplit {
    private typealias Scalars = ArraySlice<Unicode.Scalar>

    /// nil when the Python splitter would raise `Unsupported`.
    static func english(_ text: String) -> Words? {
        let s = Array(text.unicodeScalars)
        var ranges: [Range<Int>] = []
        var i = 0
        while i < s.count {
            if isSpace(s[i]) { i += 1; continue }
            var j = i
            while j < s.count && !isSpace(s[j]) { j += 1 }
            guard let found = units(s[i..<j]) else { return nil }
            ranges += found
            i = j
        }
        guard !ranges.isEmpty else { return nil }
        var utf16 = [0]
        for c in s { utf16.append(utf16[utf16.count - 1] + (c.value > 0xFFFF ? 2 : 1)) }
        return Words(text: text, all: ranges.map {
            Words.Word(string: String(String.UnicodeScalarView(s[$0])), utf16: utf16[$0.lowerBound]..<utf16[$0.upperBound])
        })
    }

    private static func units(_ c: Scalars) -> [Range<Int>]? {
        var start = c.startIndex, end = c.endIndex
        var lead: [Range<Int>] = [], trail: [Range<Int>] = []
        while start < end && leading.contains(c[start]) {
            if apostrophes.contains(c[start]) && start + 1 < end && isAlnum(c[start + 1]) { break }
            lead.append(start..<start + 1)
            start += 1
        }
        while end > start && trailing.contains(c[end - 1]) {
            let rest = c[start..<end]
            if rest.allSatisfy(dots.contains) { break }
            if rest.last == "." && (abbreviations.contains(fold(rest)) || isInitialism(rest)) { break }
            var run = end - 1
            while run > start && c[run - 1] == c[end - 1] && runs.contains(c[end - 1]) { run -= 1 }
            trail.insert(run..<end, at: 0)
            end = run
        }
        guard start < end else { return lead + trail }
        guard let middle = coreWords(c[start..<end]), !middle.contains(where: \.isEmpty) else { return nil }
        return lead + middle + trail
    }

    private static func coreWords(_ core: Scalars) -> [Range<Int>]? {
        if isURLish(core) || isInitialism(core) || abbreviations.contains(fold(core)) { return [core.indices] }
        let first = core.startIndex
        if core.count > 1 && currencies.contains(core[first]) && isDigit(core[first + 1]) {
            return clitics(core.dropFirst()).map { [first..<first + 1] + $0 }
        }
        return clitics(core)
    }

    private static func clitics(_ part: Scalars) -> [Range<Int>]? {
        let lowered = fold(part)
        if let length = fused[lowered] {
            let cut = min(part.startIndex + length, part.endIndex)
            return [part.startIndex..<cut, cut..<part.endIndex]
        }
        for clitic in cliticTails where lowered.count > clitic.count && lowered.suffix(clitic.count).elementsEqual(clitic) {
            let cut = max(part.endIndex - clitic.count, part.startIndex)
            if part[..<cut].contains(where: apostrophes.contains) { return nil }
            return [part.startIndex..<cut, cut..<part.endIndex]
        }
        return [part.indices]
    }

    private static func isInitialism(_ s: Scalars) -> Bool {
        let pairs = stride(from: s.startIndex, to: s.endIndex, by: 2)
        if s.count >= 4 && s.count % 2 == 0 && pairs.allSatisfy({ isASCIILetter(s[$0]) && s[$0 + 1] == "." }) { return true }
        return s.count == 2 && ("A"..."Z").contains(s[s.startIndex]) && s.last == "."
    }

    private static func isURLish(_ s: Scalars) -> Bool {
        for prefix in ["http://", "https://", "www."] where s.count > prefix.unicodeScalars.count && s.starts(with: prefix.unicodeScalars) {
            return true
        }
        guard let at = s.firstIndex(of: "@"), at > s.startIndex, let dot = s.lastIndex(of: ".") else { return false }
        return dot >= at + 2 && dot + 1 < s.endIndex && s[(dot + 1)...].allSatisfy { isAlnum($0) || $0 == "_" }
    }

    /// Python `str.casefold`, exact for comparing with ASCII keys. The other non-ASCII scalars whose fold has
    /// ASCII in it (ß, ẞ, K, İ, ǰ, ẖ, ẗ, ẘ, ẙ, ẚ, ﬀ-ﬄ) cannot reach a key or a clitic tail.
    private static func fold(_ s: Scalars) -> [Unicode.Scalar] {
        s.flatMap { c -> [Unicode.Scalar] in
            switch c {
            case "A"..."Z": [Unicode.Scalar(UInt8(c.value + 32))]
            case "\u{2019}": ["'"]
            case "\u{17F}": ["s"]
            case "\u{FB05}", "\u{FB06}": ["s", "t"]
            case "\u{149}": ["\u{2BC}", "n"]
            default: [c]
            }
        }
    }

    // Python 3.10 is Unicode 13.0; later scalars are unassigned there.
    private static func inPython(_ c: Unicode.Scalar) -> Bool { (c.properties.age?.major ?? .max) <= 13 }

    static func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace || ("\u{1C}"..."\u{1F}").contains(c) }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { inPython(c) && c.properties.generalCategory == .decimalNumber }

    private static func isASCIILetter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }

    static func isAlnum(_ c: Unicode.Scalar) -> Bool {
        guard inPython(c) else { return false }
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return c.properties.numericType != nil
        }
    }

    private static func scalars(_ s: String) -> Set<Unicode.Scalar> { Set(s.unicodeScalars) }
    private static func keys(_ s: [String]) -> Set<[Unicode.Scalar]> { Set(s.map { Array($0.unicodeScalars) }) }

    private static let apostrophes = scalars("'\u{2019}")
    private static let leading = scalars("\"'\u{2018}\u{201C}([{<\u{BF}\u{A1}")
    private static let trailing = scalars("\"'\u{2019}\u{201D})]}>.,!?;:\u{2026}")
    private static let dots = scalars(".\u{2026}")
    private static let runs = scalars(".!?")
    private static let currencies = scalars("$\u{20AC}\u{A3}")
    private static let cliticTails = ["n't", "'s", "'m", "'re", "'ve", "'ll", "'d"].map { Array($0.unicodeScalars) }
    private static let fused: [[Unicode.Scalar]: Int] = [
        "cannot": 3, "gonna": 3, "wanna": 3, "gotta": 3, "can't": 2, "won't": 2, "ain't": 2, "shan't": 3,
    ].reduce(into: [:]) { $0[Array($1.key.unicodeScalars)] = $1.value }
    private static let abbreviations = keys([
        "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "jr.", "sr.", "vs.", "etc.", "inc.", "ltd.", "co.", "corp.", "al.",
        "c.", "e.g.", "i.e.", "a.m.", "p.m.", "jan.", "feb.", "aug.", "sept.", "oct.", "nov.", "dec.",
    ])
}
