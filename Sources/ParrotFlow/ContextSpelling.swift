import Foundation

/// Respells a dictated span the way the screen already writes it, when the
/// sentence model prefers the rewrite.
///
/// A port of the `context_spelling` prototype, rules and numbers unchanged.
/// Terms come from the screen captured at press. Each span of one to four
/// words is matched against each term by letters, by sound or by one misheard
/// small word, and Qwen scores the sentence as heard against each rewrite. A
/// rewrite is kept when its gain clears the floor for its kind of match.
///
/// Runs after the last pipeline step when `transcription.context_spelling` is
/// on. Offsets are UTF-16, into the transcript.
enum ContextSpelling {

    /// Floors on the gain in nats, one per kind of match. A near match by
    /// letters or sound needs `margin`: swept on 44 cases, 42/44 at 1 and 0,
    /// 41/44 at 3 and 2.
    static let margin = 1.0
    /// Same letters as an identifier. Every exact match of 44 measured was a
    /// wanted write.
    static let exactFloor = -6.0
    /// Same letters as a term that cannot be English. Two right writes scored
    /// -8.0 and -12.0.
    static let codeFloor = -35.0
    /// A name off the window, near-missed. Right writes scored -6.4 and -6.8.
    static let personFloor = -8.0
    static let prefixChars = 2000
    /// Seconds before scoring gives up and the text goes through as
    /// dictated. The prototype's client timeout.
    static let budget: TimeInterval = 5
    static let minRatio = 0.8
    static let soundFloor = 0.85

    enum Kind: String {
        case plain, name, ident, code

        var isCode: Bool { self == .ident || self == .code }
    }

    /// What the capture read off the window, and the text above the caret when
    /// there is no screen.
    struct Screen {
        var text: String
        var code: [String] = []
        var place = ""
        var people: [String] = []
        var roster: [String] = []
    }

    struct Candidate: Codable {
        let start: Int
        let end: Int
        let span: String
        let term: String
        let ratio: Double
        let sound: Double
        let exact: Bool
        let code: Bool
        let person: Bool
        let byword: Bool
        var delta: Double?
    }

    /// Terms in the order they were first seen. The order decides which
    /// candidate wins an exact tie.
    struct Terms {
        private(set) var order: [String] = []
        private(set) var kinds: [String: Kind] = [:]

        mutating func add(_ term: String, _ kind: Kind) {
            guard kinds[term] == nil else { return }
            order.append(term)
            kinds[term] = kind
        }

        mutating func set(_ term: String, _ kind: Kind) {
            if kinds[term] == nil { order.append(term) }
            kinds[term] = kind
        }

        mutating func remove(_ term: String) {
            guard kinds.removeValue(forKey: term) != nil else { return }
            order.removeAll { $0 == term }
        }
    }

    // MARK: - The stage

    static func apply(to text: String, scope: Scope) async -> StageResult {
        let unchanged = StageResult(text: text, vars: ["count": .int(0)])
        var language = "en"
        if case .string(let named)? = scope["language"] { language = named }
        let screen = captured(scope: scope)
        guard !clean(screen.text).isEmpty else {
            Log.write("context spelling: no screen and no text above the caret")
            return unchanged
        }
        let found = candidates(
            in: text, screen: screen, voice: Phonemes.voice(for: language),
            tokens: Tagger.tokens(in: text, language: language)
        )
        guard !found.isEmpty else {
            Log.write("context spelling: no candidate")
            return unchanged
        }
        guard await SentenceReadings.shared.isLoaded else {
            Log.write("context spelling: \(found.count) candidate(s) left alone;"
                + " the sentence model is not in memory yet")
            return unchanged
        }
        let started = CFAbsoluteTimeGetCurrent()
        let totals: [Double]
        do {
            totals = try await SentenceReadings.shared.totals(
                prefix: prefix(of: clean(screen.text)),
                continuations: [text] + found.map { rewrite(text, with: [$0]) },
                budget: budget
            )
        } catch {
            Log.write("context spelling: \(error.localizedDescription); left as dictated")
            return unchanged
        }
        let ms = ((CFAbsoluteTimeGetCurrent() - started) * 1000).rounded()
        let scored = ranked(scoring(found, totals))
        let chosen = choose(scored)
        let changes = chosen.map(described).joined(separator: "; ")
        let best = scored.max { ($0.delta ?? 0) < ($1.delta ?? 0) }.map(described) ?? ""
        Log.write("context spelling: \(scored.count) candidate(s), best \(best)"
            + (changes.isEmpty ? "" : ", wrote \(changes)") + String(format: ", %.0fms", ms))
        return StageResult(text: rewrite(text, with: chosen), vars: [
            "count": .int(chosen.count),
            "score_ms": .double(ms),
            "changes": .string(changes),
            "best": .string(best),
        ])
    }

    /// The screen at press, or the text above the caret when the screen is
    /// blank. Read here rather than from `context.*`, so the switch works
    /// without the `context` stage.
    static func captured(scope: Scope) -> Screen {
        var screen = Screen(text: "")
        if case .success(let capture)? = Context.pressCapture?.outcome {
            screen = Screen(text: capture.text, code: capture.code, place: capture.place,
                            people: capture.people, roster: capture.roster)
        }
        if screen.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           case .int(let run)? = scope["press.run"],
           case .success(let box)? = InputBox.capture(for: run)?.outcome {
            screen.text = [box.before, box.text].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        }
        return screen
    }

    static func described(_ candidate: Candidate) -> String {
        "\(candidate.span) -> \(candidate.term) (" + String(format: "%+.1f", candidate.delta ?? 0) + ")"
    }

    // MARK: - Choosing

    /// Each candidate's gain over the sentence as heard. `totals[0]` is the
    /// sentence as heard.
    static func scoring(_ candidates: [Candidate], _ totals: [Double]) -> [Candidate] {
        guard totals.count == candidates.count + 1 else { return [] }
        return zip(candidates, totals.dropFirst()).map { candidate, total in
            var scored = candidate
            scored.delta = total - totals[0]
            return scored
        }
    }

    /// Longest first, then the largest gain.
    static func ranked(_ candidates: [Candidate]) -> [Candidate] {
        candidates.enumerated().sorted {
            let (a, b) = ($0.element, $1.element)
            if a.end - a.start != b.end - b.start { return a.end - a.start > b.end - b.start }
            if a.delta != b.delta { return (a.delta ?? 0) > (b.delta ?? 0) }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    /// Longest first among those that clear their floor, with no overlaps.
    static func choose(_ candidates: [Candidate]) -> [Candidate] {
        var chosen: [Candidate] = []
        for candidate in ranked(candidates) {
            let floor: Double
            if candidate.exact {
                floor = candidate.code ? codeFloor : exactFloor
            } else if candidate.byword {
                floor = -margin
            } else {
                floor = candidate.person ? personFloor : margin
            }
            guard let delta = candidate.delta, delta >= floor,
                  !chosen.contains(where: { candidate.start < $0.end && $0.start < candidate.end })
            else { continue }
            chosen.append(candidate)
        }
        return chosen
    }

    static func rewrite(_ text: String, with chosen: [Candidate]) -> String {
        let out = NSMutableString(string: text)
        for candidate in chosen.sorted(by: { $0.start > $1.start }) {
            out.replaceCharacters(
                in: NSRange(location: candidate.start, length: candidate.end - candidate.start),
                with: candidate.term)
        }
        return out as String
    }

    // MARK: - The screen

    static func clean(_ context: String) -> String {
        context
            .replacingOccurrences(
                of: #"[─-▟⎿❯✻※ ]+"#, with: " ",
                options: .regularExpression)
            .components(separatedBy: "\n")
            .map {
                $0.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The last 2000 characters as Python counts them, then a newline.
    static func prefix(of context: String) -> String {
        String(context.unicodeScalars.suffix(prefixChars)) + "\n"
    }

    private static let identifier = try? NSRegularExpression(pattern:
        #"`([^`\n]{3,40})`"#
        + #"|(?<![\w.\-/])([A-Za-z][A-Za-z0-9]*(?:[._\-/][A-Za-z0-9]+)+"#
        + #"|[a-z]+[A-Z][A-Za-z0-9]*|[A-Z]{2,}[a-z][A-Za-z0-9]*|[A-Z][a-z]+[A-Z][A-Za-z0-9]*"#
        + #"|[A-Za-z]+\d[A-Za-z0-9]*)(?![\w])"#
        + #"|(?<=[a-z,;] )([A-Z][a-z]{2,})\b"#
        + #"|\b([a-z]{8,})\b"#)

    private static let fileStem = try? NSRegularExpression(
        pattern: #"^(.+)\.(?:py|swift|sh|ya?ml|json|md|js|ts|tsx|txt|toml|rs|go|rb|c|h|cpp)$"#)

    /// Backticked runs, identifiers, capitalised names mid-sentence and long
    /// lowercase words, in the order the screen shows them.
    static func terms(in context: String) -> Terms {
        var found = Terms()
        let whole = context as NSString
        for match in identifier?.matches(in: context, range: NSRange(location: 0, length: whole.length)) ?? [] {
            guard let group = (1...4).first(where: { match.range(at: $0).location != NSNotFound })
            else { continue }
            var term = whole.substring(with: match.range(at: group))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let after = NSMaxRange(match.range)
            // A terminal draws `name()` without backticks.
            if group == 2, after < whole.length, whole.character(at: after) == 0x28 { term += "()" }
            guard norm(term).count >= 4, term.split(whereSeparator: \.isWhitespace).count <= 3
            else { continue }
            found.add(term, group == 4 ? .plain : group == 3 ? .name : .ident)
            // A file is often said without its extension.
            let range = NSRange(location: 0, length: (term as NSString).length)
            if let stem = fileStem?.firstMatch(in: term, range: range).map({
                (term as NSString).substring(with: $0.range(at: 1))
            }), stem.range(of: #"[_\-]|[a-z][A-Z]|\d"#, options: .regularExpression) != nil,
               norm(stem).count >= 4 {
                found.add(stem, .ident)
            }
        }
        for term in found.order where term.hasSuffix("()") {
            found.remove(String(term.dropLast(2)))
        }
        return found
    }

    // MARK: - Candidates

    static let edgeTags: Set<String> = [
        "Determiner", "Pronoun", "Preposition", "Conjunction", "Particle", "Interjection", "Adverb",
    ]
    static let edgeWords: Set<String> = [
        "the", "a", "an", "to", "of", "and", "or", "in", "on", "at", "for", "is", "it", "that",
        "this", "my", "your", "we", "i", "here", "there",
    ]
    /// Small words the recogniser swaps.
    static let misheard: Set<Set<String>> = [
        ["of", "off"], ["to", "two"], ["to", "too"], ["too", "two"], ["for", "four"],
    ]

    private static let nonSpace = try? NSRegularExpression(pattern: #"[^\s]+"#)
    private static let trailing = Set(".,;:!?\"')".utf16)
    private static let leading = Set("\"'(".utf16)

    static func candidates(
        in text: String, screen: Screen, voice: String, tokens: [Tagger.Token]
    ) -> [Candidate] {
        let context = clean(screen.text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !context.isEmpty
        else { return [] }
        let people = (screen.people + screen.roster).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let named = ([screen.place] + screen.people + screen.roster).filter { !$0.isEmpty }

        var terms = Self.terms(in: context)
        for span in screen.code where !span.isEmpty {
            for term in Self.terms(in: span).order { terms.set(term, .code) }
        }
        for term in named {
            terms.set(term, shaped(term, strippingSigil: false) ? .ident : .name)
        }
        // A surname said on its own, kept to parts of four letters and up.
        var parts: [String] = []
        for name in people {
            for part in name.split(whereSeparator: \.isWhitespace).map(String.init)
            where norm(part).count >= 4 && !parts.contains(part) {
                parts.append(part)
            }
        }
        for part in parts { terms.add(part, .name) }
        let persons = Set(people).union(parts)

        let stops = edgeStops(tokens, in: text)
        let whole = text as NSString
        let wordRuns = nonSpace?.matches(in: text, range: NSRange(location: 0, length: whole.length))
            .map { ($0.range.location, NSMaxRange($0.range)) } ?? []
        var spans: [(n: Int, start: Int, end: Int, lastAt: Int, text: String)] = []
        for n in 1...4 where wordRuns.count >= n {
            for i in 0...(wordRuns.count - n) {
                var start = wordRuns[i].0, end = wordRuns[i + n - 1].1
                let lastAt = wordRuns[i + n - 1].0
                while end > start, trailing.contains(whole.character(at: end - 1)) { end -= 1 }
                while start < end, leading.contains(whole.character(at: start)) { start += 1 }
                let span = whole.substring(with: NSRange(location: start, length: end - start))
                if norm(span).count >= 4, terms.kinds[span] == nil {
                    spans.append((n, start, end, lastAt, span))
                }
            }
        }

        var forms: [String: [String]] = [:]
        var heard: [String: String] = [:]
        var phrases: [String] = []
        for span in spans where heard[span.text] == nil {
            heard[span.text] = spokenHeard(span.text)
            phrases.append(spokenHeard(span.text))
        }
        for term in terms.order {
            forms[term] = spoken(term)
            phrases += spoken(term)
        }
        let ipa = sounds(of: phrases, voice: voice)

        func soundsLike(_ span: String, _ term: String) -> Double {
            guard let a = heard[span].flatMap({ ipa[$0] }), !a.isEmpty else { return 0 }
            var best = 0.0
            for form in forms[term] ?? [] {
                guard let b = ipa[form], !b.isEmpty else { continue }
                let (x, y) = (Double(a.unicodeScalars.count), Double(b.unicodeScalars.count))
                if min(x, y) / max(x, y) >= soundFloor * soundFloor {
                    best = max(best, Double(Phonemes.similarity(a, b)))
                }
            }
            return best
        }

        var out: [Candidate] = []
        for span in spans {
            let ns = norm(span.text)
            for term in terms.order {
                guard let kind = terms.kinds[term] else { continue }
                let nt = norm(term)
                if span.text.lowercased() == term.lowercased(), !kind.isCode { continue }
                let exact = ns == nt
                let ratio = abs(nt.count - ns.count) <= 3 ? matchRatio(ns, nt) : 0
                let byLetters = exact || (nt.first != nil && nt.first == ns.first && ratio >= minRatio)
                let byWord = kind.isCode && oneWordMisheard(span.text, term)
                let similar = exact || byWord ? 1 : soundsLike(span.text, term)
                guard byLetters || byWord || similar >= soundFloor else { continue }
                if !(exact || byWord), span.n > 1 {
                    let said = runs(of: span.text.lowercased())
                    let named = Set((forms[term] ?? []).flatMap { runs(of: $0.lowercased()) })
                    let edges: [String?] = stops.isEmpty
                        ? [said.first, said.last].map { $0.flatMap { edgeWords.contains($0) ? $0 : nil } }
                        : [stops[span.start], stops[span.lastAt]]
                    if edges.contains(where: { $0.map { !named.contains($0) } ?? false }) { continue }
                }
                let unknown = words(in: span.text).filter { !known($0) }
                if kind == .plain, unknown.isEmpty, similar < soundFloor { continue }
                if !(exact || byWord), span.n > 1, unknown.isEmpty, similar < soundFloor { continue }
                out.append(Candidate(
                    start: span.start, end: span.end, span: span.text, term: term,
                    ratio: ratio, sound: (similar * 100).rounded() / 100,
                    exact: exact && kind.isCode,
                    code: kind == .code || shaped(term, strippingSigil: true),
                    person: persons.contains(term),
                    byword: byWord
                ))
            }
        }
        return out
    }

    /// Character offsets, as UTF-16, a span may not start or end on.
    static func edgeStops(_ tokens: [Tagger.Token], in text: String) -> [Int: String] {
        var stops: [Int: String] = [:]
        for token in tokens where edgeTags.contains(token.tag) {
            guard let at = text.index(text.startIndex, offsetBy: token.at, limitedBy: text.endIndex)
            else { continue }
            stops[at.utf16Offset(in: text)] = token.text.lowercased()
        }
        return stops
    }

    /// Whether a term could not have been said as ordinary English: a
    /// separator, an inner capital or a digit.
    static func shaped(_ term: String, strippingSigil: Bool) -> Bool {
        let bare = strippingSigil
            ? term.replacingOccurrences(of: "^[#@]", with: "", options: .regularExpression) : term
        return bare.range(of: #"[_\-./]|[a-z][A-Z]|\d"#, options: .regularExpression) != nil
    }

    /// All words the same except one small word the recogniser swaps.
    static func oneWordMisheard(_ span: String, _ term: String) -> Bool {
        let said = runs(of: span.lowercased())
        for form in spoken(term) {
            let want = runs(of: form.lowercased())
            guard said.count == want.count, said.count >= 2 else { continue }
            let diff = zip(said, want).filter { $0 != $1 }
            if diff.count == 1, let pair = diff.first, misheard.contains([pair.0, pair.1]) {
                return true
            }
        }
        return false
    }

    // MARK: - Words

    static func norm(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0)
        }.map(Character.init))
    }

    private static func runs(of text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
            .filter { !$0.isEmpty }
    }

    private static let wordOrNumber = try? NSRegularExpression(pattern: #"[A-Za-z]+|\d+"#)

    private static func words(in text: String) -> [String] {
        let whole = text as NSString
        return wordOrNumber?.matches(in: text, range: NSRange(location: 0, length: whole.length))
            .map { whole.substring(with: $0.range) } ?? []
    }

    /// `/usr/share/dict/words`, lowercased. It has no plurals.
    static let dictionary: Set<String> = {
        guard let all = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)
        else { return [] }
        return Set(all.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
    }()

    static func known(_ word: String) -> Bool {
        let w = word.lowercased()
        if !w.isEmpty, w.allSatisfy(\.isNumber) { return false }
        return dictionary.contains(w)
            || (w.hasSuffix("s") && dictionary.contains(String(w.dropLast())))
            || (w.hasSuffix("es") && dictionary.contains(String(w.dropLast(2))))
    }

    /// `difflib.SequenceMatcher(None, a, b).ratio()`, without the junk
    /// heuristic, which only starts at 200 characters.
    static func matchRatio(_ a: String, _ b: String) -> Double {
        let (x, y) = (Array(a.utf8), Array(b.utf8))
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return 2 * Double(matched(x, 0, x.count, y, 0, y.count)) / Double(x.count + y.count)
    }

    /// The longest common block, earliest in `a` then in `b` on a tie, and
    /// the same again either side of it.
    private static func matched(
        _ a: [UInt8], _ alo: Int, _ ahi: Int, _ b: [UInt8], _ blo: Int, _ bhi: Int
    ) -> Int {
        guard alo < ahi, blo < bhi else { return 0 }
        var (besti, bestj, size) = (alo, blo, 0)
        var previous = [Int](repeating: 0, count: bhi - blo + 1)
        for i in alo..<ahi {
            var current = [Int](repeating: 0, count: bhi - blo + 1)
            for j in blo..<bhi where a[i] == b[j] {
                let k = previous[j - blo] + 1
                current[j - blo + 1] = k
                if k > size { (besti, bestj, size) = (i - k + 1, j - k + 1, k) }
            }
            previous = current
        }
        guard size > 0 else { return 0 }
        return size + matched(a, alo, besti, b, blo, bestj)
            + matched(a, besti + size, ahi, b, bestj + size, bhi)
    }

    // MARK: - Sound

    /// How an identifier is said: `context_of()` as "context of", a dot said
    /// as "dot" or not at all.
    static func spoken(_ term: String) -> [String] {
        var said = term.replacingOccurrences(of: #"\(\)$"#, with: "", options: .regularExpression)
        said = said.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        said = said.replacingOccurrences(
            of: #"([A-Za-z])(\d)|(\d)([A-Za-z])"#, with: "$1$3 $2$4", options: .regularExpression)
        said = said.replacingOccurrences(of: #"[_\-/]+"#, with: " ", options: .regularExpression)
        func squeezed(_ text: String) -> String {
            text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Set([
            squeezed(said.replacingOccurrences(of: ".", with: " dot ")),
            squeezed(said.replacingOccurrences(of: ".", with: " ")),
        ]).sorted()
    }

    static func spokenHeard(_ span: String) -> String {
        span.replacingOccurrences(of: #"[^\w']+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// IPA per phrase, in one espeak call. Empty when espeak is missing or
    /// answers a different number of lines, which zeroes every sound match.
    static func sounds(of phrases: [String], voice: String) -> [String: String] {
        var unique: [String] = []
        var seen = Set<String>()
        for phrase in phrases where !phrase.isEmpty && seen.insert(phrase).inserted {
            unique.append(phrase)
        }
        guard !unique.isEmpty, let binary = Phonemes.binary,
              let lines = Phonemes.run(binary, unique, voice: voice) else { return [:] }
        return Dictionary(zip(unique, lines), uniquingKeysWith: { first, _ in first })
    }
}
