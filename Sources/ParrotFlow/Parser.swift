import Accelerate
import CoreML
import Foundation

/// The syrinx parse of one window of words. Core ML runs the `parse` and `ner`
/// encoders of the parrotflow-syrinx package; the heads in
/// `syrinx-heads.safetensors` run here.
final class Parser: @unchecked Sendable {

    enum Failure: LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let what): return "syrinx parser: \(what)"
            }
        }
    }

    static let length = 256
    static let width = 384
    /// NER reads at most this many words at once, as in training.
    static let nerWords = 96

    struct Word {
        let upos: String
        let feats: [String: String]
        /// 1-based within the window, 0 for its root.
        let head: Int
        let deprel: String
        /// Indexed like `tagNames`.
        let tags: [Float]
    }

    struct Window {
        let words: [Word]
        /// Per word, the type of the NER span holding it.
        let ner: [String?]
        let ids: [Int]
        let nerIDs: [[Int]]
        let parseSeconds: Double
        let nerSeconds: Double
    }

    let tagNames: [String]
    private let parseModel: MLModel
    private let nerModel: MLModel
    private let tokenizer: ScalarBPE
    private let heads: Heads
    private let ner: NERHead
    private let adapters: [String: MLMultiArray]
    private let bos: Int
    private let eos: Int

    /// What `syrinx-heads.safetensors` holds, read before any model loads: a
    /// file that will not read is the bundle's fault, and a fetch cannot fix it.
    struct Weights {
        fileprivate let heads: Heads
        fileprivate let ner: NERHead
        fileprivate let adapters: [String: MLMultiArray]

        init(contentsOf url: URL) throws {
            let tensors = try Tensors(contentsOf: url)
            heads = try Heads(tensors)
            ner = try NERHead(tensors)
            adapters = try Parser.adapterInputs(tensors)
        }
    }

    init(parse: MLModel, ner: MLModel, tokenizer: ScalarBPE, weights: Weights) throws {
        guard let bos = tokenizer.id(of: "<bos>"), let eos = tokenizer.id(of: "<eos>") else {
            throw Failure.malformed("the tokenizer has no <bos> or <eos>")
        }
        parseModel = parse
        nerModel = ner
        self.tokenizer = tokenizer
        heads = weights.heads
        self.ner = weights.ner
        tagNames = weights.heads.tagNames
        adapters = weights.adapters
        self.bos = bos
        self.eos = eos
    }

    /// `PARROTFLOW_SYRINX_HEADS` overrides the bundled file, for tests.
    static var headsURL: URL {
        let override = ProcessInfo.processInfo.environment["PARROTFLOW_SYRINX_HEADS"] ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if !Permissions.isRunningFromBuildDirectory,
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("syrinx-heads.safetensors"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("built-in/data/syrinx-heads.safetensors")
    }

    private static let adapterNames = ["g_qkv_A", "g_qkv_B", "g_o_A", "g_o_B", "s_qkv_A", "s_qkv_B", "s_o_A", "s_o_B"]

    private static func adapterInputs(_ tensors: Tensors) throws -> [String: MLMultiArray] {
        var out: [String: MLMultiArray] = [:]
        for name in adapterNames {
            let key = "adapters.\(name)"
            guard let shape = tensors.shape(key), shape.count == 3 else {
                throw Failure.malformed("no \(key)")
            }
            let halves = try tensors.halves(key, shape: shape)
            let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
            array.withUnsafeMutableBufferPointer(ofType: Float16.self) { out, strides in
                precondition(strides == [shape[1] * shape[2], shape[2], 1])
                for at in halves.indices { out[at] = halves[at] }
            }
            out[name] = array
        }
        return out
    }

    /// `[bos]`, each word encoded on its own, `[eos]`, and each word's subwords.
    func subwords(_ words: [String]) -> (ids: [Int], spans: [Range<Int>]) {
        var ids = [bos]
        var spans: [Range<Int>] = []
        for word in words {
            let piece = tokenizer.encode(word)
            spans.append(ids.count ..< ids.count + piece.count)
            ids += piece
        }
        ids.append(eos)
        return (ids, spans)
    }

    /// The 13 type queries, each after `<eos>`, then `<eos>` and the words.
    private func nerWords(_ words: [String]) -> (joint: [String], labels: [[Int]], start: Int) {
        var joint: [String] = []
        var labels: [[Int]] = []
        for type in ner.types {
            joint.append("<eos>")
            let start = joint.count
            joint += type.split(separator: " ").map(String.init)
            labels.append(Array(start ..< joint.count))
        }
        joint.append("<eos>")
        return (joint, labels, joint.count)
    }

    func fits(_ words: [String]) -> Bool {
        words.isEmpty || subwords(words).ids.count <= Self.length
    }

    private func nerFits(_ words: [String]) -> Bool {
        subwords(nerWords(words).joint + words).ids.count <= Self.length
    }

    /// `cut_filter_nv.envelope.Model.chunks`: at most 96 words, halved until the NER input fits.
    func chunks(_ words: [String]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var a = 0
        while a < words.count {
            var b = min(words.count, a + Self.nerWords)
            while b - a > 1 && !nerFits(Array(words[a ..< b])) { b = a + (b - a) / 2 }
            out.append(a ..< b)
            a = b
        }
        return out
    }

    /// Nil when the words do not fit one parse or the tree has no single root.
    /// Throws `ParseField.Abstained` for a one-word NER chunk that does not fit.
    func analyse(_ words: [String]) throws -> Window? {
        guard !words.isEmpty else { return nil }
        let (ids, spans) = subwords(words)
        guard ids.count <= Self.length, !spans.contains(where: \.isEmpty) else { return nil }

        var started = DispatchTime.now().uptimeNanoseconds
        let output = try predict(parseModel, ids, extra: adapters)
        guard let parsed = heads.analyse(
            g: try rows(output, "g_hidden", count: ids.count),
            s: try rows(output, "s_hidden", count: ids.count),
            spans: spans
        ) else { return nil }
        let parseSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9

        started = DispatchTime.now().uptimeNanoseconds
        var types = [String?](repeating: nil, count: words.count)
        var nerIDs: [[Int]] = []
        for chunk in chunks(words) {
            let part = Array(words[chunk])
            let (joint, labels, start) = nerWords(part)
            let (ids, spans) = subwords(joint + part)
            nerIDs.append(ids)
            guard ids.count <= Self.length else {
                throw ParseField.Abstained(.subwords, "a one-word NER chunk over \(Self.length) subwords")
            }
            let hidden = try rows(try predict(nerModel, ids, extra: [:]), "n_hidden", count: ids.count)
            for (at, type) in ner.decode(hidden: hidden, spans: spans, labels: labels, start: start, count: part.count)
                .enumerated() {
                types[chunk.lowerBound + at] = type
            }
        }
        let nerSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        return Window(words: parsed, ner: types, ids: ids, nerIDs: nerIDs,
                      parseSeconds: parseSeconds, nerSeconds: nerSeconds)
    }

    private func predict(_ model: MLModel, _ ids: [Int], extra: [String: MLMultiArray]) throws -> MLFeatureProvider {
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.length)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: Self.length)], dataType: .int32)
        input.withUnsafeMutableBufferPointer(ofType: Int32.self) { out, _ in
            for at in 0 ..< Self.length { out[at] = at < ids.count ? Int32(ids[at]) : 0 }
        }
        mask.withUnsafeMutableBufferPointer(ofType: Int32.self) { out, _ in
            for at in 0 ..< Self.length { out[at] = at < ids.count ? 1 : 0 }
        }
        var features: [String: Any] = ["input_ids": input, "attention_mask": mask]
        for (name, array) in extra { features[name] = array }
        return try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
    }

    private func rows(_ output: MLFeatureProvider, _ name: String, count: Int) throws -> [Float] {
        let width = Self.width
        guard let array = output.featureValue(for: name)?.multiArrayValue,
              array.dataType == .float32,
              array.shape.map(\.intValue) == [1, Self.length, width],
              array.strides.map(\.intValue) == [Self.length * width, width, 1]
        else { throw Failure.malformed("\(name) is not a contiguous [1, 256, 384] float32") }
        return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(count * width)) }
    }

    /// First index of the largest value, like `numpy.argmax`.
    static func argmax<C: RandomAccessCollection>(_ values: C) -> Int where C.Element == Float, C.Index == Int {
        var best = values.startIndex
        for at in values.indices where values[at] > values[best] { best = at }
        return best - values.startIndex
    }
}

private struct Linear {
    let weightT: [Float]
    let bias: [Float]
    let inputs: Int
    let outputs: Int

    init(weightT: [Float], bias: [Float], inputs: Int, outputs: Int) {
        self.weightT = weightT
        self.bias = bias
        self.inputs = inputs
        self.outputs = outputs
    }

    init(_ tensors: Tensors, _ name: String, inputs: Int, outputs: Int) throws {
        let weight = try tensors.floats(name + ".weight", shape: [outputs, inputs])
        weightT = transpose(weight, rows: outputs, columns: inputs)
        bias = try tensors.floats(name + ".bias", shape: [outputs])
        self.inputs = inputs
        self.outputs = outputs
    }

    func callAsFunction(_ x: [Float], rows: Int) -> [Float] {
        var y = multiply(x, weightT, rows: rows, inner: inputs, columns: outputs)
        for row in 0 ..< rows {
            for column in 0 ..< outputs { y[row * outputs + column] += bias[column] }
        }
        return y
    }
}

/// `syrinx_full_fp16.heads.Applier.analyse`, without the pooled vectors.
private struct Heads {
    struct Segment: Decodable { let key: String; let offset: Int; let size: Int; let values: [String] }

    let grammar: Linear
    let layout: [Segment]
    let fusionT: [Float]
    let root: [Float]
    let arcDep: Linear, arcHead: Linear, relDep: Linear, relHead: Linear
    let arc: [Float]
    /// Projection width plus the bias column.
    static let arcWidth = 129, relWidth = 65
    let relWide: [Float]
    /// No `root`: the label head never scores it.
    let labels: [String]
    let tagNames: [String]
    let tagHidden: Linear, tagOut: Linear

    init(_ tensors: Tensors) throws {
        labels = try tensors.json([String].self, "relations")
        guard !labels.contains("root") else { throw Parser.Failure.malformed("a label head that scores root") }
        let relations = labels.count
        layout = try tensors.json([Segment].self, "inventories")
        guard layout.first?.key == "upos", layout[0].offset == 0,
              zip(layout, layout.dropFirst()).allSatisfy({ $0.offset + $0.size == $1.offset })
        else { throw Parser.Failure.malformed("an inventory layout this code does not read") }
        let width = Parser.width, features = layout.reduce(0) { $0 + $1.size }
        let a = Self.arcWidth, r = Self.relWidth
        var weight: [Float] = [], bias: [Float] = []
        for segment in layout {
            weight += try tensors.floats("head.layers.\(segment.key).weight", shape: [segment.size, width])
            bias += try tensors.floats("head.layers.\(segment.key).bias", shape: [segment.size])
        }
        grammar = Linear(weightT: transpose(weight, rows: features, columns: width), bias: bias,
                         inputs: width, outputs: features)
        fusionT = transpose(try tensors.floats("fusion.weight", shape: [width, features]), rows: width, columns: features)
        root = try tensors.floats("parser.root", shape: [width])
        arcDep = try Linear(tensors, "parser.arc_dep.0", inputs: width, outputs: a - 1)
        arcHead = try Linear(tensors, "parser.arc_head.0", inputs: width, outputs: a - 1)
        relDep = try Linear(tensors, "parser.rel_dep.0", inputs: width, outputs: r - 1)
        relHead = try Linear(tensors, "parser.rel_head.0", inputs: width, outputs: r - 1)
        arc = try tensors.floats("parser.arc.weight", shape: [1, a, a])
        let rel = try tensors.floats("parser.rel.weight", shape: [relations, r, r])
        var wide = [Float](repeating: 0, count: r * relations * r)
        for o in 0 ..< relations {
            for i in 0 ..< r {
                for j in 0 ..< r { wide[i * relations * r + o * r + j] = rel[(o * r + i) * r + j] }
            }
        }
        relWide = wide
        tagNames = (tensors.string("tag_order") ?? "").split(separator: ",").map(String.init)
        guard tagNames.count == 4 else { throw Parser.Failure.malformed("a tag head without four tags") }
        tagHidden = try Linear(tensors, "tags.net.0", inputs: width, outputs: 128)
        tagOut = try Linear(tensors, "tags.net.3", inputs: 128, outputs: 4)
    }

    func analyse(g: [Float], s: [Float], spans: [Range<Int>]) -> [Parser.Word]? {
        let n = spans.count, width = Parser.width, relations = labels.count
        let logits = grammar(pool(g, spans), rows: n)
        let features = grammar.outputs
        var probs = logits
        for row in 0 ..< n {
            for segment in layout {
                softmax(&probs[row * features + segment.offset ..< row * features + segment.offset + segment.size])
            }
        }
        var x = root + pool(s, spans)
        let fused = multiply(probs, fusionT, rows: n, inner: features, columns: width)
        for at in 0 ..< n * width { x[width + at] += fused[at] }

        let ad = biaffineInput(arcDep, x, rows: n + 1), ah = biaffineInput(arcHead, x, rows: n + 1)
        let rd = biaffineInput(relDep, x, rows: n + 1), rh = biaffineInput(relHead, x, rows: n + 1)
        let scored = multiply(ad, arc, rows: n + 1, inner: Self.arcWidth, columns: Self.arcWidth)
        let arcs = multiply(scored, transpose(ah, rows: n + 1, columns: Self.arcWidth),
                            rows: n + 1, inner: Self.arcWidth, columns: n + 1)
        let heads = SpanningTree.heads(arcs: arcs, size: n + 1)
        guard heads.filter({ $0 == 0 }).count == 1 else { return nil }

        var tags = tagOut(tagHidden(Array(x[width...]), rows: n).map(elu), rows: n)
        for row in 0 ..< n { softmax(&tags[row * 4 ..< (row + 1) * 4]) }

        var words: [Parser.Word] = []
        for (index, head) in heads.enumerated() {
            var upos = ""
            var feats: [String: String] = [:]
            for segment in layout {
                let start = index * features + segment.offset
                let value = segment.values[Parser.argmax(logits[start ..< start + segment.size])]
                if segment.key == "upos" { upos = value } else if value != "<ABSENT>" { feats[segment.key] = value }
            }
            var deprel = "root"
            if head != 0 {
                let dep = index + 1, r = Self.relWidth
                let wide = multiply(Array(rd[dep * r ..< (dep + 1) * r]), relWide, rows: 1, inner: r, columns: relations * r)
                let scores = (0 ..< relations).map { o in
                    zip(wide[o * r ..< (o + 1) * r], rh[head * r ..< (head + 1) * r]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                }
                deprel = labels[Parser.argmax(scores)]
            }
            words.append(Parser.Word(upos: upos, feats: feats, head: head, deprel: deprel,
                                     tags: Array(tags[index * 4 ..< (index + 1) * 4])))
        }
        return words
    }

    private func biaffineInput(_ layer: Linear, _ x: [Float], rows: Int) -> [Float] {
        let y = layer(x, rows: rows), columns = layer.outputs
        var out: [Float] = []
        out.reserveCapacity(rows * (columns + 1))
        for row in 0 ..< rows {
            out += y[row * columns ..< (row + 1) * columns].map(elu)
            out.append(1)
        }
        return out
    }
}

/// `gliner_style_ner_v1.MatchingHead` and `ner_fixed.decode.decode`.
private struct NERHead {
    struct Block {
        let first: Linear
        let normWeight: [Float]
        let normBias: [Float]
        let last: Linear

        init(_ tensors: Tensors, _ name: String, inputs: Int) throws {
            first = try Linear(tensors, "\(name).0", inputs: inputs, outputs: 128)
            normWeight = try tensors.floats("\(name).2.weight", shape: [128])
            normBias = try tensors.floats("\(name).2.bias", shape: [128])
            last = try Linear(tensors, "\(name).3", inputs: 128, outputs: 128)
        }

        func callAsFunction(_ x: [Float], rows: Int) -> [Float] {
            var y = first(x, rows: rows).map(gelu)
            for row in 0 ..< rows {
                let slice = row * 128 ..< (row + 1) * 128
                let mean = y[slice].reduce(0, +) / 128
                let variance = y[slice].reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / 128
                let scale = 1 / (variance + 1e-5).squareRoot()
                for (k, at) in slice.enumerated() { y[at] = (y[at] - mean) * scale * normWeight[k] + normBias[k] }
            }
            return last(y, rows: rows)
        }
    }

    let span: Block
    let label: Block
    let bias: Float
    let types: [String]
    let threshold: Double
    let width: Int

    init(_ tensors: Tensors) throws {
        span = try Block(tensors, "ner.span", inputs: 3 * Parser.width)
        label = try Block(tensors, "ner.label", inputs: Parser.width)
        bias = try tensors.floats("ner.bias", shape: [])[0]
        types = try tensors.json([String].self, "ner_types")
        guard let threshold = tensors.string("ner_threshold").flatMap(Double.init),
              let width = tensors.string("ner_width").flatMap(Int.init), width > 0
        else { throw Parser.Failure.malformed("no ner_threshold or ner_width") }
        self.threshold = threshold
        self.width = width
    }

    /// Per word, the type of the span holding it.
    func decode(hidden: [Float], spans: [Range<Int>], labels: [[Int]], start: Int, count n: Int) -> [String?] {
        let d = Parser.width
        let w = pool(hidden, spans)
        var queries = [Float](repeating: 0, count: labels.count * d)
        for (t, index) in labels.enumerated() {
            for column in 0 ..< d {
                var sum: Float = 0
                for j in index { sum += w[j * d + column] }
                queries[t * d + column] = sum / Float(index.count)
            }
        }
        let typed = label(queries, rows: labels.count)

        var cs = [Float](repeating: 0, count: (n + 1) * d)
        var running = [Double](repeating: 0, count: d)
        for k in 0 ..< n {
            for column in 0 ..< d {
                running[column] += Double(w[(start + k) * d + column])
                cs[(k + 1) * d + column] = Float(running[column])
            }
        }
        var candidates: [(a: Int, b: Int)] = []
        for a in 0 ..< n { for b in a ..< min(n, a + width) { candidates.append((a, b)) } }
        var x = [Float](repeating: 0, count: candidates.count * 3 * d)
        for (c, (a, b)) in candidates.enumerated() {
            let row = c * 3 * d, size = Float(b - a + 1)
            for column in 0 ..< d {
                x[row + column] = w[(start + a) * d + column]
                x[row + d + column] = w[(start + b) * d + column]
                x[row + 2 * d + column] = (cs[(b + 1) * d + column] - cs[a * d + column]) / size
            }
        }
        let spanned = span(x, rows: candidates.count)
        let scores = multiply(spanned, transpose(typed, rows: labels.count, columns: 128),
                              rows: candidates.count, inner: 128, columns: labels.count)
        let root = Float(Double(128).squareRoot())
        var options: [(p: Float, a: Int, b: Int, k: Int)] = []
        for (c, (a, b)) in candidates.enumerated() {
            let p = (0 ..< labels.count).map { 1 / (1 + expf(-(scores[c * labels.count + $0] / root + bias))) }
            let k = Parser.argmax(p)
            if Double(p[k]) >= threshold { options.append((p[k], a, b, k)) }
        }
        options.sort { ($0.p, $1.a, $1.b) > ($1.p, $0.a, $0.b) }
        var out = [String?](repeating: nil, count: n)
        for option in options where (option.a ... option.b).allSatisfy({ out[$0] == nil }) {
            for at in option.a ... option.b { out[at] = types[option.k] }
        }
        return out
    }
}

/// Mean per word, rounded through float16 as the reference does.
private func pool(_ hidden: [Float], _ spans: [Range<Int>]) -> [Float] {
    let width = Parser.width
    var out = [Float](repeating: 0, count: spans.count * width)
    for (word, span) in spans.enumerated() {
        let share = 1 / Float(span.count)
        for column in 0 ..< width {
            var sum: Float = 0
            for at in span { sum += share * hidden[at * width + column] }
            out[word * width + column] = Float(Float16(sum))
        }
    }
    return out
}

private func softmax(_ values: inout ArraySlice<Float>) {
    let top = values.max() ?? 0
    var sum: Float = 0
    for at in values.indices {
        values[at] = expf(values[at] - top)
        sum += values[at]
    }
    for at in values.indices { values[at] /= sum }
}

private func multiply(_ a: [Float], _ b: [Float], rows: Int, inner: Int, columns: Int) -> [Float] {
    var c = [Float](repeating: 0, count: rows * columns)
    vDSP_mmul(a, 1, b, 1, &c, 1, vDSP_Length(rows), vDSP_Length(columns), vDSP_Length(inner))
    return c
}

private func elu(_ x: Float) -> Float { x > 0 ? x : expm1(x) }

private func gelu(_ x: Float) -> Float { x * 0.5 * (1 + erff(x * Float(0.5.squareRoot()))) }

private func transpose(_ a: [Float], rows: Int, columns: Int) -> [Float] {
    var t = [Float](repeating: 0, count: a.count)
    vDSP_mtrans(a, 1, &t, 1, vDSP_Length(columns), vDSP_Length(rows))
    return t
}

/// A safetensors file: an 8-byte header length, a JSON header, then data.
struct Tensors {
    private struct Entry: Decodable {
        let dtype: String
        let shape: [Int]
        let offsets: [Int]

        enum CodingKeys: String, CodingKey {
            case dtype, shape
            case offsets = "data_offsets"
        }
    }

    private let data: Data
    private let entries: [String: Entry]
    private let metadata: [String: String]
    private let start: Int

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count > 8 else { throw Parser.Failure.malformed("\(url.lastPathComponent) is empty") }
        let declared = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard declared > 0, declared <= UInt64(data.count - 8) else {
            throw Parser.Failure.malformed("a safetensors header")
        }
        let length = Int(declared)
        guard var raw = try JSONSerialization.jsonObject(with: data.subdata(in: 8 ..< 8 + length)) as? [String: Any] else {
            throw Parser.Failure.malformed("a safetensors header")
        }
        metadata = raw.removeValue(forKey: "__metadata__") as? [String: String] ?? [:]
        entries = try raw.mapValues {
            try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        self.data = data
        start = 8 + length
    }

    func shape(_ name: String) -> [Int]? { entries[name]?.shape }

    func string(_ key: String) -> String? { metadata[key] }

    func json<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        guard let text = metadata[key] else { throw Parser.Failure.malformed("no \(key) in the metadata") }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    /// `[]` is a scalar.
    func floats(_ name: String, shape: [Int]) throws -> [Float] {
        try values(name, dtype: "F32", shape: shape, as: Float.self)
    }

    func halves(_ name: String, shape: [Int]) throws -> [Float16] {
        try values(name, dtype: "F16", shape: shape, as: Float16.self)
    }

    private func values<T>(_ name: String, dtype: String, shape: [Int], as: T.Type) throws -> [T] {
        let count = shape.reduce(1, *), size = MemoryLayout<T>.size
        guard let entry = entries[name], entry.dtype == dtype, entry.shape == shape,
              entry.offsets.count == 2, entry.offsets[0] >= 0,
              entry.offsets[1] <= data.count - start,
              entry.offsets[1] - entry.offsets[0] == count * size
        else { throw Parser.Failure.malformed("\(name) is not a \(dtype) \(shape)") }
        let from = start + entry.offsets[0]
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.withUnsafeBytes { bytes in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[from ..< from + count * size]))
            }
            initialized = count
        }
    }
}
