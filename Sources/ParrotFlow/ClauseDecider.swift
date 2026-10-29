import CryptoKit
import Foundation

/// Decides a vocabulary place from the parser clause around it, in place of
/// `TermPortrait`. One sign-constrained logistic regression over: how close the
/// clause is to the term's accepted and refused sentences, whether the heard
/// span is an entity, the part of speech of the heard word and its
/// neighbours, how it sounds against the term, whether it is a dictionary
/// word, and whether this exact swap was accepted or refused before.
///
/// Ported from `training/syntax-parser/vocab_clause_core.py`; the weights were
/// fitted on public text only. Behind `transcription.vocabulary.clause_decider`.
enum ClauseDecider {

    enum Decision: String {
        case write, leave, offer
    }

    struct Features {
        var simAccepted: Double?
        var simRefused: Double?
        var ner = 0.0
        var heardPropn = 0.0
        var heardNonnominal = 0.0
        var prevDet = 0.0
        var prevAdp = 0.0
        var nextVerb = 0.0
        var sound = 0.0
        var known = 0.0
        var pairAccepted = 0.0
        var pairRefused = 0.0

        /// In `Model.names` order.
        var fitted: [Double?] {
            [simAccepted, simRefused, ner, heardPropn, heardNonnominal, prevDet, prevAdp, nextVerb, sound, known]
        }
    }

    struct Reading {
        let features: Features
        let z: Double
        let p: Double
        let decision: Decision
        /// No accepted sentence to compare with: such a term never writes.
        var cold: Bool { features.simAccepted == nil }
        /// Scalar offsets of the pooled words in the text that was parsed.
        let clause: Range<Int>?
    }

    // MARK: - The weights

    struct Model: Sendable {
        static let names = [
            "sim_acc", "sim_ref", "ner", "heard_propn", "heard_nonnominal", "prev_det", "prev_adp", "next_verb",
            "sound", "known",
        ]
        static let width = Parser.width, projected = 256, nerLabels = 11

        let centre: [Float]
        let projection: [Float]
        let nerWeight: [Float]
        let nerBias: [Float]
        let weights: [Double]
        let means: [Double]
        let deviations: [Double]
        let bias: Double
        /// For `sim_acc` and `sim_ref`: the value when the feature is absent.
        let absent: [Double]
        /// For `pair_acc` and `pair_ref`, set by hand.
        let fixed: [Double]
        /// Features that may only lower z. A refused-sentence match pushes
        /// toward leaving; its absence is no evidence for writing. Both ways,
        /// one off-topic refusal wrote `red rock` as Redrock on the bench.
        let oneSided: Set<Int>
        /// A single-term place's pair_acc counts only when sim_acc is present
        /// and at least its mean: a correction made in a deploy clause wrote
        /// Vercel over a castle's "Versailles" (sim_acc 0.061).
        let pairGate: Bool
        let write: Double
        let leave: Double
        let minimumPool: Int
        /// Names the row-vector store, so another set of weights never reads
        /// vectors this one wrote.
        let tag: String

        init(contentsOf url: URL) throws {
            let tensors = try Tensors(try MappedFile(url))
            func list(_ key: String) -> [String]? {
                tensors.string(key).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
            }
            guard list("features") == Self.names, list("absent") == ["sim_acc", "sim_ref"],
                  list("fixed") == ["pair_acc", "pair_ref"]
            else { throw Parser.Failure.malformed("the clause decider's features are not in the order this code reads") }
            guard let write = tensors.string("write").flatMap(Double.init),
                  let leave = tensors.string("leave").flatMap(Double.init),
                  let pool = tensors.string("min_pool").flatMap(Int.init)
            else { throw Parser.Failure.malformed("the clause decider has no thresholds") }
            let count = Self.names.count
            centre = try tensors.floats("centre", shape: [Self.width])
            projection = try tensors.floats("proj", shape: [Self.width, Self.projected])
            nerWeight = try tensors.floats("ner.weight", shape: [Self.nerLabels, Self.width])
            nerBias = try tensors.floats("ner.bias", shape: [Self.nerLabels])
            weights = try tensors.floats("w", shape: [count]).map(Double.init)
            means = try tensors.floats("mu", shape: [count]).map(Double.init)
            deviations = try tensors.floats("sd", shape: [count]).map(Double.init)
            bias = Double(try tensors.floats("bias", shape: [1])[0])
            absent = try tensors.floats("absent", shape: [2]).map(Double.init)
            fixed = try tensors.floats("fixed", shape: [2]).map(Double.init)
            oneSided = Set((list("one_sided") ?? []).compactMap { Self.names.firstIndex(of: $0) })
            pairGate = tensors.string("pair_gate") == "sim_acc"
            self.write = write
            self.leave = leave
            minimumPool = pool
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            tag = "\(SyrinxModel.revision.prefix(8))-\(digest.prefix(8))"
        }

        /// Bundled, like `wordpiece.txt`: the assembled app's Resources, else
        /// the source tree for the raw `swift build` product.
        static var fileURL: URL {
            if !Permissions.isRunningFromBuildDirectory,
               let bundled = Bundle.main.resourceURL?.appendingPathComponent("vocab-clause.safetensors"),
               FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
            return URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("built-in/data/vocab-clause.safetensors")
        }

        static let shared: Result<Model, Error> = Result { try Model(contentsOf: fileURL) }

        func score(_ f: Features) -> Double {
            var z = bias
            for (k, value) in f.fitted.enumerated() {
                if let value {
                    let part = weights[k] * (value - means[k]) / deviations[k]
                    z += oneSided.contains(k) ? min(0, part) : part
                } else if k < absent.count {
                    z += absent[k]
                }
            }
            return z + fixed[0] * f.pairAccepted + fixed[1] * f.pairRefused
        }

        func decide(_ f: Features, clause: Range<Int>?) -> Reading {
            let z = score(f)
            let p = 1 / (1 + exp(-z))
            let decision: Decision
            if f.simAccepted == nil {
                decision = p >= leave ? .offer : .leave
            } else {
                decision = p >= write ? .write : p < leave ? .leave : .offer
            }
            return Reading(features: f, z: z, p: p, decision: decision, clause: clause)
        }
    }

    // MARK: - One parsed text

    /// A text as the vocabulary stage reads it: tokenised and windowed as
    /// `TreeCutter.Clip` does, every offset in `Unicode.Scalar`s.
    struct Parsed {
        let clip: TreeCutter.Clip
        let ends: [Int]

        init(_ text: String, parser: Parser) {
            clip = TreeCutter.Clip(text, parser: parser)
            ends = clip.tokens.map { $0.start + $0.string.unicodeScalars.count }
        }

        var count: Int { clip.tokens.count }

        func span(_ range: Range<Int>) -> [Int] {
            (0 ..< count).filter { clip.tokens[$0].start < range.upperBound && ends[$0] > range.lowerBound }
        }

        private static let column = Dictionary(uniqueKeysWithValues: UPOS.allCases.enumerated().map { ($1, $0) })

        func probability(_ token: Int, _ tag: UPOS) -> Double {
            Double(clip.uposProbabilities[token * UPOS.allCases.count + (Self.column[tag] ?? 0)])
        }

        func hasAlnum(_ token: Int) -> Bool {
            clip.tokens[token].string.unicodeScalars.contains(where: WordSplit.isAlnum)
        }
    }

    private static let clausal: Set<String> = ["advcl", "ccomp", "xcomp", "conj", "acl", "parataxis", "csubj"]
    private static let subject: Set<String> = ["nsubj", "csubj", "cop"]
    private static let skipped: Set<String> = ["mark", "cc"]

    /// The clause holding the span. From the first span token whose head is
    /// outside the span, up to the first clause head: a window root, or a word
    /// on a clausal relation that is a predicate (a verb, or a word with a
    /// subject or copula child). A nominal conj is not one, so "Mirza and
    /// Mira" stays in its sentence's clause. Then that head's subtree, without
    /// going into another clause head or into mark and cc words.
    static func clause(_ parsed: Parsed, span: [Int]) -> [Int] {
        let clip = parsed.clip
        let heads = clip.heads.map { $0 - 1 }
        var kids: [Int: [Int]] = [:]
        for (j, h) in heads.enumerated() { kids[h, default: []].append(j) }
        let inside = Set(span)
        let anchor = span.first { !inside.contains(heads[$0]) } ?? span[0]
        func isHead(_ j: Int) -> Bool {
            if clip.labels[j] == "root" || heads[j] < 0 { return true }
            let predicate = clip.upos[j] == "VERB" || clip.upos[j] == "AUX"
                || (kids[j] ?? []).contains { subject.contains(clip.labels[$0]) }
            return clausal.contains(clip.labels[j]) && predicate
        }
        var h = anchor
        while !isHead(h) { h = heads[h] }
        var out: [Int] = [], stack = [h]
        while let x = stack.popLast() {
            out.append(x)
            stack += (kids[x] ?? []).filter { !isHead($0) && !skipped.contains(clip.labels[$0]) }
        }
        return out.sorted()
    }

    /// The clause minus the span and minus tokens with no letter or digit; the
    /// span's whole parse window when fewer than `minimum` are left.
    static func pool(_ parsed: Parsed, span: [Int], minimum: Int) -> [Int] {
        let inside = Set(span)
        let keep = { (tokens: [Int]) in tokens.filter { !inside.contains($0) && parsed.hasAlnum($0) } }
        let found = keep(clause(parsed, span: span))
        if found.count >= minimum { return found }
        guard let window = parsed.clip.windows.first(where: { $0.contains(span[0]) }) else { return [] }
        return keep(Array(window))
    }

    static func vector(_ parsed: Parsed, tokens: [Int], model: Model) -> [Float]? {
        guard !tokens.isEmpty else { return nil }
        let width = Model.width, out = Model.projected
        var mean = [Float](repeating: 0, count: width)
        for t in tokens {
            for d in 0 ..< width { mean[d] += parsed.clip.vectors[t * width + d] }
        }
        for d in 0 ..< width { mean[d] = mean[d] / Float(tokens.count) - model.centre[d] }
        var projected = [Float](repeating: 0, count: out)
        for i in 0 ..< width where mean[i] != 0 {
            let x = mean[i]
            for j in 0 ..< out { projected[j] += x * model.projection[i * out + j] }
        }
        return unit(projected)
    }

    static func unit(_ v: [Float]) -> [Float]? {
        let norm = Float(v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot())
        return norm > 0 ? v.map { $0 / norm } : nil
    }

    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors {
            for i in sum.indices { sum[i] += v[i] }
        }
        return unit(sum)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    }

    /// max over the span of 1 - P(O), O being label 0.
    static func entity(_ parsed: Parsed, span: [Int], model: Model) -> Double {
        let width = Model.width, labels = Model.nerLabels
        var best = 0.0
        for t in span {
            var logits = model.nerBias.map(Double.init)
            for k in 0 ..< labels {
                var z = 0.0
                for d in 0 ..< width {
                    z += Double(model.nerWeight[k * width + d]) * Double(parsed.clip.fused[t * width + d])
                }
                logits[k] += z
            }
            let top = logits.max() ?? 0
            let e = logits.map { exp($0 - top) }
            best = max(best, 1 - e[0] / e.reduce(0, +))
        }
        return best
    }

    private static let nonnominal: [UPOS] = [.verb, .aux, .adv, .adp, .det, .pron, .cconj, .sconj, .part]

    static func partsOfSpeech(_ parsed: Parsed, span: [Int], into f: inout Features) {
        guard let first = span.min(), let last = span.max() else { return }
        f.heardPropn = span.map { parsed.probability($0, .propn) }.max() ?? 0
        f.heardNonnominal = span.map { t in nonnominal.reduce(0.0) { $0 + parsed.probability(t, $1) } }.max() ?? 0
        let before = (0 ..< first).reversed().first(where: parsed.hasAlnum)
        let after = (last + 1 ..< parsed.count).first(where: parsed.hasAlnum)
        f.prevDet = before.map { parsed.probability($0, .det) } ?? 0
        f.prevAdp = before.map { parsed.probability($0, .adp) } ?? 0
        f.nextVerb = after.map { parsed.probability($0, .verb) + parsed.probability($0, .aux) } ?? 0
    }

    static func known(_ heard: String) -> Bool {
        var runs: [String] = [], current = ""
        for c in heard {
            if c.isLetter { current.append(c) } else if !current.isEmpty { runs.append(current); current = "" }
        }
        if !current.isEmpty { runs.append(current) }
        return !runs.isEmpty && runs.allSatisfy(ContextSpelling.known)
    }

    static func norm(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == " " })
            .trimmingCharacters(in: .whitespaces)
    }

    /// A single-term place: whether this exact swap was accepted, and refused,
    /// before. A shared place: the sign of the net counter, so a pair counter
    /// gives no member an edge another cannot earn — the member spelled like
    /// the heard form is credited with each pill choice of it and each peer
    /// put back to it, and refused once for each correction of it to a peer.
    static func pairs(
        heard: String, term: String, rows: [TermUses.Use], shared: Bool, peers: [TermUses.Use] = []
    ) -> (accepted: Double, refused: Double) {
        let h = norm(heard)
        let accepted = rows.filter { !$0.counter }
        let refused = rows.filter(\.counter)
        guard shared else {
            return (accepted.contains { $0.heard.map(norm) == h } ? 1 : 0,
                    refused.contains { norm($0.span) == h } ? 1 : 0)
        }
        var net = accepted.filter { $0.heard.map(norm) == h }.count - refused.filter { norm($0.span) == h }.count
        // A peer put back over this term at the heard words.
        net -= peers.filter { !$0.counter && norm($0.span) == h && $0.heard.map(norm) == norm(term) }.count
        if norm(term) == h {
            // Chosen on the pill, or put back over another spelling.
            net += accepted.filter { use in
                norm(use.span) == h && (use.from == .chosen || use.heard.map { norm($0) != h } == true)
            }.count
            net -= peers.filter { !$0.counter && $0.heard.map(norm) == h }.count
        }
        return (net > 0 ? 1 : 0, net < 0 ? 1 : 0)
    }

    static func sound(heard: String, term: String) -> Double {
        let ipa = Phonemes.of([heard, term], voice: Phonemes.voice(for: "en"))
        guard let a = ipa[heard], let b = ipa[term] else { return 0 }
        return Double(Phonemes.similarity(a, b))
    }

    static func place(_ parsed: Parsed, at range: Range<Int>, model: Model) -> (vector: [Float]?, span: [Int], pool: [Int]) {
        let span = parsed.span(range)
        guard !span.isEmpty else { return (nil, [], []) }
        let pooled = pool(parsed, span: span, minimum: model.minimumPool)
        return (vector(parsed, tokens: pooled, model: model), span, pooled)
    }

    /// A stored row's vector: its sentence parsed, its span found as
    /// `TermUses` finds it.
    static func rowVector(_ use: TermUses.Use, parser: Parser, model: Model) -> [Float]? {
        guard let found = TermUses.occurrence(of: use.span, in: use.said) else { return nil }
        let a = use.said.unicodeScalars.distance(from: use.said.unicodeScalars.startIndex, to: found.lowerBound)
        let b = a + use.said[found].unicodeScalars.count
        return place(Parsed(use.said, parser: parser), at: a ..< b, model: model).vector
    }

    /// One place. `text` holds the heard words at `range` (scalar offsets).
    static func read(
        _ parsed: Parsed, at range: Range<Int>, heard: String, term: String,
        accepted: [[Float]], refused: [[Float]], pairs: (accepted: Double, refused: Double),
        model: Model, shared: Bool = false
    ) -> Reading? {
        let (vector, span, pooled) = place(parsed, at: range, model: model)
        guard !span.isEmpty else { return nil }
        var f = Features()
        if let vector {
            f.simAccepted = centroid(accepted).map { cosine(vector, $0) }
            f.simRefused = centroid(refused).map { cosine(vector, $0) }
        }
        f.ner = entity(parsed, span: span, model: model)
        partsOfSpeech(parsed, span: span, into: &f)
        f.sound = sound(heard: heard, term: term)
        f.known = known(heard) ? 1 : 0
        f.pairAccepted = pairs.accepted
        if model.pairGate, !shared, (f.simAccepted ?? -.infinity) < model.means[0] { f.pairAccepted = 0 }
        f.pairRefused = pairs.refused
        var clause: Range<Int>?
        if let lo = pooled.map({ parsed.clip.tokens[$0].start }).min(), let hi = pooled.map({ parsed.ends[$0] }).max() {
            clause = lo ..< hi
        }
        return model.decide(f, clause: clause)
    }
}

extension ClauseDecider {

    /// What a net counter is worth: half of this, against a member with
    /// accepted sentences and against one with none.
    static let marginWarm = 0.15, marginCold = 0.75
    /// A lead this small is a near tie and is offered.
    static let tie = 0.02
    private static let closed: Set<String> = ["ADP", "DET", "CCONJ", "PRON", "AUX"]

    enum GroupDecision: Equatable {
        case write(String)
        /// Best first.
        case offer([String])
        case leave
    }

    /// A place several terms compete for. Every member shares the slot, so
    /// they are told apart by how close the clause is to each one's
    /// sentences, plus its net counter; p only says the slot holds a name.
    /// The best is written as soon as it leads by `tie` and clears the write
    /// bar, sentences or not; a near tie is offered. The member spelled like
    /// the heard words is the default: another must lead it to be written.
    /// Counters move a lead by half a margin at most.
    static func decideGroup(
        _ members: [(term: String, reading: Reading)], heard: String, model: Model
    ) -> GroupDecision {
        struct Candidate { let term: String; let p: Double; let sim: Double?; let net: Double }
        let all = members.map {
            Candidate(term: $0.term, p: $0.reading.p, sim: $0.reading.features.simAccepted,
                      net: $0.reading.features.pairAccepted - $0.reading.features.pairRefused)
        }
        func lead(_ t: Candidate, over u: Candidate) -> Double {
            let margin = u.sim == nil ? marginCold : marginWarm
            return (t.sim ?? 0) - (u.sim ?? 0) + margin / 2 * min(1, max(-1, t.net - u.net))
        }
        if let fallback = all.first(where: { norm($0.term) == norm(heard) }) {
            let others = all.filter { $0.term != fallback.term }
            guard let best = others.max(by: { a, b in
                let (x, y) = (lead(a, over: fallback), lead(b, over: fallback))
                return x != y ? x < y : a.p < b.p
            }) else { return .leave }
            let gap = lead(best, over: fallback)
            if gap >= tie, best.p >= model.write { return .write(best.term) }
            if abs(gap) < tie || (gap >= tie && best.p >= model.leave) { return .offer([best.term, fallback.term]) }
            return .leave
        }
        let ranked = all.sorted { a, b in
            let (x, y) = ((a.sim ?? 0) + marginWarm / 2 * a.net, (b.sim ?? 0) + marginWarm / 2 * b.net)
            return x != y ? x > y : a.p > b.p
        }
        guard let best = ranked.first else { return .leave }
        let gap = ranked.count > 1 ? lead(best, over: ranked[1]) : tie
        if gap >= tie, best.p >= model.write { return .write(best.term) }
        return best.p >= model.leave ? .offer(ranked.prefix(2).map(\.term)) : .leave
    }

    /// Slots a name cannot stand in: `SlotGate.blocks` read as UPOS.
    static let slotBlocks: Set<UPOS> = [.verb, .aux, .adv, .adp]

    /// What the parser expects where the heard words stand. The span's tokens
    /// become one `<mask>` in their window and the window is parsed again. UPOS
    /// probabilities at the mask; nil when no token stands at `range`.
    static func slot(_ parsed: Parsed, at range: Range<Int>, parser: Parser) -> [Float]? {
        let span = parsed.span(range)
        guard let first = span.first, let window = parsed.clip.windows.first(where: { $0.contains(first) })
        else { return nil }
        let inside = Set(span)
        var words: [String] = [], at: Int?
        for token in window {
            guard inside.contains(token) else {
                words.append(parsed.clip.tokens[token].string)
                continue
            }
            if at == nil {
                at = words.count
                words.append("<mask>")
            }
        }
        guard let at, let analysis = parser.analyse(words: Words(joining: words), language: "en") else { return nil }
        return analysis.parse.words[at].upos
    }

    /// The heard run without a closed-class first or last word the term does
    /// not also start or end with. Nil when nothing would be left.
    static func trimmed(_ parsed: Parsed, text: [Unicode.Scalar], at range: Range<Int>, term: String) -> Range<Int>? {
        var words: [Range<Int>] = []
        var i = range.lowerBound
        while i < range.upperBound {
            if WordSplit.isSpace(text[i]) { i += 1; continue }
            var j = i
            while j < range.upperBound && !WordSplit.isSpace(text[j]) { j += 1 }
            words.append(i ..< j)
            i = j
        }
        guard words.count >= 2 else { return range }
        let termWords = term.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        func closedClass(_ word: Range<Int>) -> Bool {
            guard let first = parsed.span(word).first(where: parsed.hasAlnum) else { return false }
            return closed.contains(parsed.clip.upos[first])
        }
        func spelled(_ word: Range<Int>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: text[word])
            return String(view).lowercased()
        }
        var lo = 0, hi = words.count
        if closedClass(words[0]), spelled(words[0]) != termWords.first { lo = 1 }
        if hi - lo >= 2, closedClass(words[hi - 1]), spelled(words[hi - 1]) != termWords.last { hi -= 1 }
        guard lo < hi else { return nil }
        return words[lo].lowerBound ..< words[hi - 1].upperBound
    }
}

/// The row vectors, kept on disk under a name that holds the parser revision
/// and the decider's weights, next to the Qwen portrait store.
actor ClauseStore {

    static let shared = ClauseStore()

    private var vectors: [String: [Float]] = [:]
    private var loadedTag: String?

    private static func url(_ tag: String) -> URL {
        AppVariant.supportDirectory.appendingPathComponent("portraits-parrotflow-syrinx-\(tag).json")
    }

    private static func key(_ use: TermUses.Use) -> String {
        "\(use.counter ? "-" : "+")\(use.span)\u{1}\(use.said)"
    }

    func memory(
        of rows: [TermUses.Use], parser: Parser, model: ClauseDecider.Model
    ) -> (accepted: [[Float]], refused: [[Float]]) {
        if loadedTag != model.tag {
            vectors = (try? JSONDecoder().decode([String: [Float]].self, from: Data(contentsOf: Self.url(model.tag)))) ?? [:]
            loadedTag = model.tag
        }
        var changed = false
        var accepted: [[Float]] = [], refused: [[Float]] = []
        for use in rows {
            let key = Self.key(use)
            if vectors[key] == nil {
                vectors[key] = ClauseDecider.rowVector(use, parser: parser, model: model) ?? []
                changed = true
            }
            guard let v = vectors[key], !v.isEmpty else { continue }
            if use.counter { refused.append(v) } else { accepted.append(v) }
        }
        if changed {
            let live = Set(TermUses.load().values.flatMap { $0 }.map(Self.key))
            vectors = vectors.filter { live.contains($0.key) }
            do {
                try FileManager.default.createDirectory(
                    at: AppVariant.supportDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(vectors).write(to: Self.url(model.tag), options: .atomic)
            } catch {
                Log.write("clause decider: could not keep the row vectors (\(error.localizedDescription))")
            }
        }
        return (accepted, refused)
    }
}

/// One dictation's worth of clause readings: each heard text parsed once, and
/// every place read kept for the trace.
final class ClauseSession {
    let parser: Parser
    let model: ClauseDecider.Model
    private var parsed: [String: ClauseDecider.Parsed] = [:]
    private(set) var lines: [String] = []
    private(set) var places = 0
    private(set) var tally: [ClauseDecider.Decision: Int] = [:]
    private(set) var seconds = 0.0

    init(parser: Parser, model: ClauseDecider.Model) {
        self.parser = parser
        self.model = model
    }

    /// One place, read on `text` with the heard words put back at it. The
    /// clause offsets in the trace line are mapped back to `text`.
    func read(
        _ change: VocabularyPass.Change, term: String, in text: String, counted: Bool = true, shared: Bool = false
    ) async -> ClauseDecider.Reading? {
        let started = Date()
        defer { seconds += Date().timeIntervalSince(started) }
        let heardText = text.replacingCharacters(in: change.range, with: change.was)
        let a = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: change.range.lowerBound)
        let b = a + change.was.unicodeScalars.count
        let parse = parsing(heardText)
        let stored = TermUses.load()
        let rows = stored[term] ?? []
        let peers = shared ? change.group.filter { $0 != term }.flatMap { stored[$0] ?? [] } : []
        let memory = await ClauseStore.shared.memory(of: rows, parser: parser, model: model)
        guard let reading = ClauseDecider.read(
            parse, at: a ..< b, heard: change.was, term: term,
            accepted: memory.accepted, refused: memory.refused,
            pairs: ClauseDecider.pairs(heard: change.was, term: term, rows: rows, shared: shared, peers: peers),
            model: model, shared: shared
        ) else {
            lines.append("\"\(change.was)\" -> \(term): no parser token at the place")
            return nil
        }
        if counted {
            places += 1
            tally[reading.decision, default: 0] += 1
        }
        let shift = text.unicodeScalars.count - heardText.unicodeScalars.count
        let clause = reading.clause.map { r in
            (r.lowerBound >= b ? r.lowerBound + shift : r.lowerBound) ..< (r.upperBound >= b ? r.upperBound + shift : r.upperBound)
        }
        lines.append(Self.describe(reading, heard: change.was, term: term, clause: clause,
                                   accepted: memory.accepted.count, refused: memory.refused.count))
        return reading
    }

    /// What the parser expects where the heard words stand, as the slot gate's
    /// route. Against mmBERT's slot, right declines: judge 12 vs 15, bench 25
    /// vs 25; one wrong decline ("that ___ added" read AUX 0.95) where mmBERT
    /// had none.
    func slot(_ change: VocabularyPass.Change, in text: String) -> SlotGate.Reading? {
        let started = Date()
        defer { seconds += Date().timeIntervalSince(started) }
        let heardText = text.replacingCharacters(in: change.range, with: change.was)
        let a = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: change.range.lowerBound)
        guard let upos = ClauseDecider.slot(
            parsing(heardText), at: a ..< a + change.was.unicodeScalars.count, parser: parser)
        else { return nil }
        let tag = UPOS.allCases[Parser.argmax(upos)]
        lines.append("\"\(change.was)\" slot \(tag.rawValue)")
        return SlotGate.Reading(tag: tag.rawValue, route: ClauseDecider.slotBlocks.contains(tag) ? .decline : .open)
    }

    private func parsing(_ text: String) -> ClauseDecider.Parsed {
        if let held = parsed[text] { return held }
        let parse = ClauseDecider.Parsed(text, parser: parser)
        parsed[text] = parse
        return parse
    }

    /// A place several terms compete for: every member read on the same
    /// clause, then `ClauseDecider.decideGroup`. Nil when a member cannot be read.
    func readGroup(_ change: VocabularyPass.Change, in text: String) async -> ClauseDecider.GroupDecision? {
        var members: [(term: String, reading: ClauseDecider.Reading)] = []
        for member in change.group {
            guard let reading = await read(change, term: member, in: text, counted: false, shared: true)
            else { return nil }
            members.append((member, reading))
        }
        let decision = ClauseDecider.decideGroup(members, heard: change.was, model: model)
        places += 1
        let said: String
        switch decision {
        case .write(let member):
            tally[.write, default: 0] += 1
            said = "write \(member)"
        case .offer(let top):
            tally[.offer, default: 0] += 1
            said = "offer \(top.joined(separator: "/"))"
        case .leave:
            tally[.leave, default: 0] += 1
            said = "leave"
        }
        lines.append("\"\(change.was)\" group \(change.group.joined(separator: "/")): \(said)")
        return decision
    }

    /// Sound proposals of two or more words lose a closed-class edge word the
    /// term does not share, then must still sound like the term.
    func trimmingEdges(
        _ parts: [VocabularyPass.Part], in text: String,
        sounds: [(term: String, form: String, phonemes: String?)], voice: String, floor: Float
    ) -> [VocabularyPass.Part] {
        let scalars = Array(text.unicodeScalars)
        let view = text.unicodeScalars
        return parts.compactMap { part in
            guard part.standing == .sound else { return part }
            let a = view.distance(from: view.startIndex, to: part.range.lowerBound)
            let b = view.distance(from: view.startIndex, to: part.range.upperBound)
            let kept = ClauseDecider.trimmed(parsing(text), text: scalars, at: a ..< b, term: part.term)
            guard kept != a ..< b else { return part }
            guard let kept else {
                lines.append("\"\(part.decoded)\" -> \(part.term): nothing left once the edge words go")
                return nil
            }
            let range = view.index(view.startIndex, offsetBy: kept.lowerBound) ..< view.index(view.startIndex, offsetBy: kept.upperBound)
            let words = String(text[range])
            let forms = sounds.filter { $0.term == part.term }
            let ipa = Phonemes.of([words] + forms.map(\.form), voice: voice)
            let score = forms.flatMap { [ipa[$0.form], $0.phonemes] }.compactMap { $0 }.filter { !$0.isEmpty }
                .map { form in ipa[words].map { Phonemes.similarity($0, form) } ?? 0 }.max() ?? 0
            guard score >= floor else {
                lines.append("\"\(part.decoded)\" -> \(part.term): \"\(words)\" alone scores"
                    + String(format: " %.2f, under the floor; not proposed", score))
                return nil
            }
            lines.append("\"\(part.decoded)\" -> \(part.term): proposed as \"\(words)\"" + String(format: " (%.2f)", score))
            return VocabularyPass.Part(
                range: range, decoded: words, other: Vocabulary.inflected(part.term, like: words),
                term: part.term, standing: .sound
            )
        }
    }

    static func describe(
        _ r: ClauseDecider.Reading, heard: String, term: String, clause: Range<Int>?, accepted: Int, refused: Int
    ) -> String {
        let f = r.features
        func v(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "absent" }
        let values = zip(ClauseDecider.Model.names, f.fitted).map { "\($0)=\(v($1))" }
            + ["pair_acc=\(Int(f.pairAccepted))", "pair_ref=\(Int(f.pairRefused))"]
        let span = clause.map { "[\($0.lowerBound),\($0.upperBound))" } ?? "none"
        return "\"\(heard)\" -> \(term): \(r.decision.rawValue) p=\(String(format: "%.3f", r.p))"
            + " z=\(String(format: "%.3f", r.z)) clause=\(span) rows=+\(accepted)/-\(refused) "
            + values.joined(separator: " ")
    }
}
