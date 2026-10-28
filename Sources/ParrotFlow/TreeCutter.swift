import Foundation

/// The parrotflow-syrinx tree cutter and its cut filter, ported from the
/// Python the cut check measured: `cut_check.candidates`, `audio_cue.candidates`,
/// `syrinx_retrain.tags`, `cut_check.vec`, `cut_check.clf` and
/// `cv_first_pass.labels.assemble`. Every offset counts `Unicode.Scalar`s, as
/// Python indexes code points.
enum TreeCutter {

    struct Candidate: Sendable {
        /// Filler-view word indices, sorted.
        let words: [Int]
        /// The 7 text features, in `CutFilter.textNames` order.
        let textFeatures: [Double]
        let pReal: Double
        let kept: Bool

        var a: Int { words[0] }
        var b: Int { words[words.count - 1] + 1 }
    }

    struct Outcome: Sendable {
        let text: String
        /// What the parser reads: the input with the built-in fillers removed.
        let view: String
        let candidates: [Candidate]
        /// Input word indices, sorted.
        let cut: [Int]
        let declined: String?
    }

    static func run(_ text: String, parser: Parser, filter: CutFilter, threshold: Double) -> Outcome {
        let input = Spans(text)
        let view = fillerView(text)
        let viewWords = Spans(view)
        guard let toInput = align(input.strings, viewWords.strings) else {
            return Outcome(text: text, view: view, candidates: [], cut: [], declined: "filler view")
        }
        let clip = Clip(view, parser: parser)
        var candidates: [Candidate] = []
        var cut = Set<Int>()
        let mapped = Set(toInput)
        let forms = viewWords.strings.map(norm)
        let (vectors, counts) = clip.wordVectors(words: viewWords)
        for group in clip.groups() {
            let tokens = group.sorted()
            let words = Set(tokens.compactMap { clip.tokenWord[$0 - 1] }).sorted()
            guard let a = words.first, let last = words.last else { continue }
            let b = last + 1
            let abandoned = tokens.map { Double(clip.abandoned[$0 - 1]) }
            let cue = tokens.map { Double(clip.cue[$0 - 1]) }
            let features: [Double] = [
                abandoned.max() ?? 0,
                abandoned.reduce(0, +) / Double(abandoned.count),
                cue.max() ?? 0,
                log(Double(words.count)),
                textCue(forms, words: words, b: b) ? 1 : 0,
                words == Array(a ..< b) ? 1 : 0,
                b >= forms.count ? 1 : 0,
            ]
            let parts = [Array(a ..< b), Array(b ..< b + min(4, b - a)), a > 0 ? [a - 1] : []]
            let vector = parts.flatMap { mean(vectors, counts, $0) }.map(Double.init)
            let p = filter.probability(features + vector)
            let kept = p >= threshold
            candidates.append(Candidate(words: words, textFeatures: features, pReal: p, kept: kept))
            guard kept else { continue }
            let span = words.map { toInput[$0] }.sorted()
            cut.formUnion(span)
            if let first = span.first, let end = span.last, end > first + 1 {
                cut.formUnion((first + 1 ..< end).filter { !mapped.contains($0) })
            }
        }
        let sorted = cut.sorted()
        return Outcome(
            text: cut.isEmpty ? text : assemble(text, cut: cut), view: view,
            candidates: candidates, cut: sorted, declined: nil
        )
    }

    // MARK: - Filler view

    private static let fillers = [
        "[,]?\\s*\\b(?:uh-huh|mm-hmm|erm|mhm|um|uh|hm)\\b[,]?",
        "[,]?\\s*\\bu+[hm]+\\b[,]?",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// The built-in `fillers` table, as `Replacements.exact` applies it.
    static func fillerView(_ text: String) -> String {
        var out = text
        for pattern in fillers {
            out = pattern.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out == text ? out : Replacements.tidy(out)
    }

    /// View word -> input word, matched in order on `norm` forms.
    static func align(_ input: [String], _ view: [String]) -> [Int]? {
        var mapping: [Int] = []
        for (index, word) in input.enumerated() where mapping.count < view.count {
            if norm(word) == norm(view[mapping.count]) { mapping.append(index) }
        }
        return mapping.count == view.count ? mapping : nil
    }

    // MARK: - Words and tokens

    /// The `\S+` runs of a text, as scalar ranges.
    struct Spans {
        let scalars: [Unicode.Scalar]
        let ranges: [Range<Int>]

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
            var found: [Range<Int>] = []
            var i = 0
            while i < scalars.count {
                if WordSplit.isSpace(scalars[i]) { i += 1; continue }
                var j = i
                while j < scalars.count && !WordSplit.isSpace(scalars[j]) { j += 1 }
                found.append(i ..< j)
                i = j
            }
            ranges = found
        }

        var strings: [String] { ranges.map { string(scalars[$0]) } }
    }

    struct Token {
        let string: String
        let start: Int
    }

    private static let clitics = ["n't", "n’t", "'m", "'ll", "'s", "'re", "'ve", "'d", "’m", "’ll", "’s", "’re", "’ve", "’d"]
        .map { Array($0.unicodeScalars) }

    /// `cue_rule.parse.tokenize` for English, over `scalars[range]`.
    static func tokens(_ scalars: [Unicode.Scalar], in range: Range<Int>) -> [Token] {
        var out: [Token] = []
        var i = range.lowerBound
        while i < range.upperBound {
            if WordSplit.isSpace(scalars[i]) { i += 1; continue }
            var e = i
            while e < range.upperBound && !WordSplit.isSpace(scalars[e]) { e += 1 }
            let next = e
            var s = i
            while s < e && !WordSplit.isAlnum(scalars[s]) {
                out.append(Token(string: string(scalars[s ..< s + 1]), start: s))
                s += 1
            }
            var tail: [Token] = []
            while e > s && !WordSplit.isAlnum(scalars[e - 1]) {
                tail.insert(Token(string: string(scalars[e - 1 ..< e]), start: e - 1), at: 0)
                e -= 1
            }
            if s < e {
                if let k = (s + 1 ..< e).first(where: { k in
                    clitics.contains { $0.count == e - k && zip($0, scalars[k ..< e]).allSatisfy { $0 == asciiLower($1) } }
                }) {
                    out.append(Token(string: string(scalars[s ..< k]), start: s))
                    out.append(Token(string: string(scalars[k ..< e]), start: k))
                } else {
                    out.append(Token(string: string(scalars[s ..< e]), start: s))
                }
            }
            out += tail
            i = next
        }
        return out
    }

    private static func asciiLower(_ c: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(c) ? Unicode.Scalar(UInt8(c.value + 32)) : c
    }

    /// `cue_replay.replay.windows`: runs of whole sentences that fit one parse.
    static func windows(_ scalars: [Unicode.Scalar], fits: ([Token]) -> Bool) -> [Range<Int>] {
        func sizeOK(_ range: Range<Int>) -> Bool { fits(tokens(scalars, in: range)) }
        var units: [Range<Int>] = []
        for piece in pieces(scalars, in: 0 ..< scalars.count, after: [".", "?", "!", "…"]) {
            if sizeOK(piece) { units.append(piece); continue }
            for part in pieces(scalars, in: piece, after: [","]) {
                if sizeOK(part) { units.append(part); continue }
                let runs = Spans(string(scalars[part])).ranges
                for k in stride(from: 0, to: runs.count, by: 60) {
                    let end = min(k + 60, runs.count) - 1
                    units.append(part.lowerBound + runs[k].lowerBound ..< part.lowerBound + runs[end].upperBound)
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
        return out.filter { !$0.isEmpty }
    }

    /// Splits at each whitespace run whose first scalar follows one of `after`.
    private static func pieces(_ scalars: [Unicode.Scalar], in range: Range<Int>, after: Set<Unicode.Scalar>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var at = range.lowerBound
        var i = range.lowerBound + 1
        while i < range.upperBound {
            guard WordSplit.isSpace(scalars[i]), after.contains(scalars[i - 1]) else { i += 1; continue }
            var j = i
            while j < range.upperBound && WordSplit.isSpace(scalars[j]) { j += 1 }
            out.append(at ..< i)
            at = j
            i = j + 1
        }
        out.append(at ..< range.upperBound)
        return out.filter { !$0.isEmpty }
    }

    // MARK: - The parse of a whole text

    /// `cv_first_pass.stages.parse_texts` for one text: its windows parsed one
    /// by one and joined, heads 1-based over the whole text.
    struct Clip {
        var tokens: [Token] = []
        var heads: [Int] = []
        var labels: [String] = []
        var upos: [String] = []
        var abandoned: [Float] = []
        var cue: [Float] = []
        var vectors: [Float] = []
        var fused: [Float] = []
        /// `UPOS.allCases` probabilities, 17 per token.
        var uposProbabilities: [Float] = []
        /// Token index ranges, one per parsed window.
        var windows: [Range<Int>] = []
        /// Per token, the view word holding its first scalar; nil when it has no alphanumeric.
        var tokenWord: [Int?] = []

        init(_ view: String, parser: Parser) {
            let words = Spans(view)
            let fits = { (found: [Token]) in
                found.isEmpty || parser.subwords(Words(joining: found.map(\.string))).ids.count <= Parser.length
            }
            guard words.scalars.contains(where: { !WordSplit.isSpace($0) }) else { return }
            for window in TreeCutter.windows(words.scalars, fits: fits) {
                let found = TreeCutter.tokens(words.scalars, in: window)
                guard !found.isEmpty,
                      let analysis = parser.analyse(words: Words(joining: found.map(\.string)), language: "en")
                else { continue }
                let base = tokens.count
                tokens += found
                windows.append(base ..< tokens.count)
                heads += analysis.parse.words.map { $0.head == 0 ? 0 : $0.head + base }
                labels += analysis.parse.words.map(\.label)
                upos += analysis.parse.words.map(\.tag.rawValue)
                uposProbabilities += analysis.parse.words.flatMap(\.upos)
                abandoned += analysis.abandoned
                cue += analysis.cue
                vectors += analysis.vectors
                fused += analysis.fused
            }
            tokenWord = tokens.map { token in
                guard token.string.unicodeScalars.contains(where: WordSplit.isAlnum) else { return nil }
                return words.ranges.firstIndex { $0.contains(token.start) }
            }
        }

        /// `cut_check.vec.word_vectors`: per view word, the sum of its token
        /// vectors and their count.
        func wordVectors(words: Spans) -> (sums: [[Float]], counts: [Int]) {
            var sums = [[Float]](repeating: [Float](repeating: 0, count: Parser.width), count: words.ranges.count)
            var counts = [Int](repeating: 0, count: words.ranges.count)
            for (t, word) in tokenWord.enumerated() {
                guard let word else { continue }
                for d in 0 ..< Parser.width { sums[word][d] += vectors[t * Parser.width + d] }
                counts[word] += 1
            }
            return (sums, counts)
        }

        private func subtree(_ node: Int) -> Set<Int> {
            var found: Set<Int> = [node]
            while true {
                let extra = Set(heads.indices.filter { found.contains(heads[$0]) }.map { $0 + 1 }).subtracting(found)
                if extra.isEmpty { return found }
                found.formUnion(extra)
            }
        }

        private func isFiller(_ i: Int) -> Bool { labels[i - 1] == "discourse" || upos[i - 1] == "INTJ" }

        private func gapCues(_ gap: Range<Int>) -> Set<Int> {
            let fillers = Set(gap.filter(isFiller))
            var found = fillers
            for j in gap where !fillers.contains(j) && upos[j - 1] != "PUNCT" {
                var k = heads[j - 1]
                while gap.contains(k) && !fillers.contains(k) { k = heads[k - 1] }
                if fillers.contains(k) { found.insert(j) }
            }
            return found
        }

        private static let afterCues: Set<String> = ["no", "sorry", "non", "pardon", "perdón", "perdon"]

        /// The cue words that go with one reparandum arc.
        private func cues(dependent: Int, head: Int, span: Set<Int>) -> Set<Int> {
            guard let top = span.max(), head > top else { return [] }
            var found = gapCues(top + 1 ..< head)
            var k = head + 1
            while k <= tokens.count && upos[k - 1] == "PUNCT" { k += 1 }
            if k <= tokens.count, isFiller(k), Self.afterCues.contains(tokens[k - 1].string.lowercased()),
               subtree(head).contains(k) {
                found.insert(k)
            }
            return found
        }

        private var arcs: [(dependent: Int, head: Int)] {
            heads.indices.compactMap { index in
                labels[index] == "reparandum" && heads[index] != 0 ? (index + 1, heads[index]) : nil
            }
        }

        /// `derive_tags` then `cut`: abandoned and cue tokens that are not punctuation.
        private func cutSet() -> Set<Int> {
            var abandoned = Set<Int>(), cue = Set<Int>()
            for arc in arcs {
                let span = subtree(arc.dependent)
                abandoned.formUnion(span)
                cue.formUnion(cues(dependent: arc.dependent, head: arc.head, span: span))
            }
            return Set((1 ... max(tokens.count, 1)).filter {
                $0 <= tokens.count && (abandoned.contains($0) || cue.contains($0)) && upos[$0 - 1] != "PUNCT"
            })
        }

        /// `audio_cue.candidates.groups`: cut tokens per arc, chains and overlaps merged.
        func groups() -> [Set<Int>] {
            guard !tokens.isEmpty else { return [] }
            let cut = cutSet()
            var groups: [(tokens: Set<Int>, repairs: Set<Int>)] = []
            for arc in arcs {
                let span = subtree(arc.dependent)
                let found = span.union(cues(dependent: arc.dependent, head: arc.head, span: span)).intersection(cut)
                if !found.isEmpty { groups.append((found, [arc.head])) }
            }
            var merged = true
            while merged {
                merged = false
                search: for i in groups.indices {
                    for j in groups.indices where j > i {
                        let a = groups[i], b = groups[j]
                        if !a.tokens.isDisjoint(with: b.tokens) || !a.repairs.isDisjoint(with: b.tokens)
                            || !b.repairs.isDisjoint(with: a.tokens) || !a.repairs.isDisjoint(with: b.repairs) {
                            groups[i] = (a.tokens.union(b.tokens), a.repairs.union(b.repairs))
                            groups.remove(at: j)
                            merged = true
                            break search
                        }
                    }
                }
            }
            return groups.map(\.tokens)
        }
    }

    // MARK: - Features

    private static let markers = ["i mean", "i meant", "no", "sorry", "or rather", "wait", "actually", "scratch that", "strike that"]
        .map { $0.split(separator: " ").map(String.init) }

    /// `cut_check.candidates.text_cue`. The cut words come in the order a
    /// CPython set of them iterates, as the measured code read them.
    static func textCue(_ forms: [String], words: [Int], b: Int) -> Bool {
        let after = (b ..< min(forms.count, b + 2)).map { forms[$0] }
        let seq = pythonSetOrder(words).map { forms[$0] } + ["|"] + after
        return markers.contains { marker in
            seq.indices.contains { k in k + marker.count <= seq.count && Array(seq[k ..< k + marker.count]) == marker }
        }
    }

    /// The iteration order of CPython 3.10's `set(values)` for distinct
    /// non-negative ints given in ascending order: the hash is the value,
    /// probing and resizing as `setobject.c` does them.
    static func pythonSetOrder(_ values: [Int]) -> [Int] {
        var table = [Int?](repeating: nil, count: 8)
        func insert(_ value: Int, into table: inout [Int?]) {
            let mask = table.count - 1
            var perturb = value
            var i = value & mask
            while true {
                if table[i] == nil { table[i] = value; return }
                if i + 9 <= mask {
                    for j in 1 ... 9 where table[i + j] == nil {
                        table[i + j] = value
                        return
                    }
                }
                perturb >>= 5
                i = (i * 5 + 1 + perturb) & mask
            }
        }
        var used = 0
        for value in values {
            insert(value, into: &table)
            used += 1
            if used * 5 >= (table.count - 1) * 3 {
                var size = 8
                while size <= used * 4 { size <<= 1 }
                var grown = [Int?](repeating: nil, count: size)
                for entry in table.compactMap({ $0 }) { insert(entry, into: &grown) }
                table = grown
            }
        }
        return table.compactMap { $0 }
    }

    /// `cut_check.vec.of_cand`'s mean: token-weighted, rounded through float16.
    private static func mean(_ sums: [[Float]], _ counts: [Int], _ words: [Int]) -> [Float] {
        let kept = words.filter { $0 < counts.count && counts[$0] > 0 }
        guard !kept.isEmpty else { return [Float](repeating: 0, count: Parser.width) }
        var total = [Float](repeating: 0, count: Parser.width)
        for word in kept {
            for d in 0 ..< Parser.width { total[d] += sums[word][d] }
        }
        let count = Float(kept.reduce(0) { $0 + counts[$1] })
        return total.map { Float(Float16($0 / count)) }
    }

    // MARK: - Text

    /// `cv_first_pass.labels.norm`.
    static func norm(_ word: String) -> String {
        let folded = word.lowercased().replacingOccurrences(of: "’", with: "'")
        var kept = String.UnicodeScalarView()
        for c in folded.unicodeScalars where WordSplit.isAlnum(c) || c == "_" || c == "'" { kept.append(c) }
        var scalars = Array(kept)
        while scalars.first == "'" { scalars.removeFirst() }
        while scalars.last == "'" { scalars.removeLast() }
        return string(scalars[...])
    }

    private static let common = Set("""
        the a an and but so or if when then because that this these those there here it its it's they them their
        we our you your he she his her my me what which who how why where some any all no not yes yeah well like just also
        to of in on at for with from by about as is are was were be been have has had do does did can could will would
        should might must one two three first after before now maybe okay ok
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    private static let enders: Set<Unicode.Scalar> = [".", "?", "!", "…"]

    private static func endsSentence(_ word: String) -> Bool {
        word.unicodeScalars.last.map(enders.contains) ?? false
    }

    /// `cv_first_pass.labels.assemble`: the text with the cut words removed.
    static func assemble(_ text: String, cut: Set<Int>) -> String {
        var ws = Spans(text).strings
        var out: [String] = []
        var i = 0
        while i < ws.count {
            guard cut.contains(i) else { out.append(ws[i]); i += 1; continue }
            var j = i
            while j < ws.count && cut.contains(j) { j += 1 }
            let first = ws[i], last = ws[j - 1]
            let crossedQuestion = (i ..< j).contains { ws[$0].contains("?") }
            if j == ws.count {
                let end = String(String.UnicodeScalarView(last.unicodeScalars.reversed().prefix { enders.contains($0) }.reversed()))
                if let previous = out.last, !end.isEmpty, !endsSentence(previous) {
                    var scalars = Array(previous.unicodeScalars)
                    while let c = scalars.last, ",;:".unicodeScalars.contains(c) { scalars.removeLast() }
                    out[out.count - 1] = string(scalars[...]) + end
                }
                i = j
                continue
            }
            var next = ws[j]
            let startsSentence = out.last.map(endsSentence) ?? true
            if startsSentence, first.unicodeScalars.first?.properties.isUppercase == true,
               next.unicodeScalars.first?.properties.isLowercase == true {
                next = firstScalar(next).uppercased() + dropFirstScalar(next)
            } else if !startsSentence, next.unicodeScalars.first?.properties.isUppercase == true,
                      common.contains(norm(next)), !norm(next).hasPrefix("i") {
                next = firstScalar(next).lowercased() + dropFirstScalar(next)
            }
            if crossedQuestion {
                var k = j
                while k < ws.count && !endsSentence(ws[k]) { k += 1 }
                if k < ws.count, ws[k].unicodeScalars.last == "." {
                    ws[k] = dropLastScalar(ws[k]) + "?"
                    if k == j { next = dropLastScalar(next) + "?" }
                }
            }
            out.append(next)
            i = j + 1
        }
        return out.joined(separator: " ")
    }

    private static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func firstScalar(_ s: String) -> String { string(s.unicodeScalars.prefix(1)) }
    private static func dropFirstScalar(_ s: String) -> String { string(s.unicodeScalars.dropFirst()) }
    private static func dropLastScalar(_ s: String) -> String { string(s.unicodeScalars.dropLast()) }
}

/// The logistic regression that keeps or drops a tree-cutter cut.
struct CutFilter: Sendable {
    static let textNames = [
        "max P(abandoned)", "mean P(abandoned)", "max P(cue)", "log length", "text cue", "contiguous", "at end",
    ]
    static let names = textNames + ["removed", "next", "before"].flatMap { part in
        (0 ..< Parser.width).map { "\(part)[\($0)]" }
    }

    let weights: [Double]
    let bias: Double
    let means: [Double]
    let deviations: [Double]
    let threshold: Double

    init(contentsOf url: URL) throws {
        let tensors = try Tensors(try MappedFile(url))
        let count = Self.names.count
        guard let text = tensors.string("features"),
              let features = try? JSONDecoder().decode([String].self, from: Data(text.utf8)),
              features == Self.names
        else { throw Parser.Failure.malformed("the cut filter's features are not in the order this code reads") }
        guard let written = tensors.string("threshold").flatMap(Double.init), (0 ... 1).contains(written) else {
            throw Parser.Failure.malformed("the cut filter has no threshold")
        }
        weights = try tensors.floats("w", shape: [count]).map(Double.init)
        bias = Double(try tensors.floats("b", shape: [1])[0])
        means = try tensors.floats("mu", shape: [count]).map(Double.init)
        deviations = try tensors.floats("sd", shape: [count]).map(Double.init)
        threshold = written
    }

    /// P(real) = sigmoid(((x - mu) / sd) . w + b).
    func probability(_ x: [Double]) -> Double {
        var z = bias
        for i in x.indices { z += (x[i] - means[i]) / deviations[i] * weights[i] }
        return 1 / (1 + exp(-z))
    }
}
