import Accelerate
import CoreML
import Foundation

struct Words: Equatable, Sendable {
    struct Word: Equatable, Sendable {
        let string: String
        /// `[start, end)` in UTF-16 code units of `text`.
        let utf16: Range<Int>
    }

    let text: String
    let all: [Word]

    init(text: String, all: [Word]) {
        self.text = text
        self.all = all
    }

    init(joining strings: [String]) {
        var all: [Word] = []
        var at = 0
        for string in strings {
            if !all.isEmpty { at += 1 }
            let end = at + string.utf16.count
            all.append(Word(string: string, utf16: at ..< end))
            at = end
        }
        self.init(text: strings.joined(separator: " "), all: all)
    }
}

/// The Universal Dependencies part-of-speech tags, in the model's order.
enum UPOS: String, CaseIterable, Sendable {
    case adj = "ADJ", adp = "ADP", adv = "ADV", aux = "AUX", cconj = "CCONJ", det = "DET"
    case intj = "INTJ", noun = "NOUN", num = "NUM", part = "PART", pron = "PRON", propn = "PROPN"
    case punct = "PUNCT", sconj = "SCONJ", sym = "SYM", verb = "VERB", x = "X"
}

struct Parse: Equatable, Sendable {
    struct Word: Equatable, Sendable {
        /// Indexed like `UPOS.allCases`.
        let upos: [Float]
        /// 1-based index of the head word, 0 for the root.
        let head: Int
        let label: String

        var tag: UPOS { UPOS.allCases[Parser.argmax(upos)] }
    }

    let words: [Word]
}

/// Core ML runs the two encoder passes; everything after them runs here.
/// Inside the Core ML graph, the heads changed 2 of 3312 fixture trees and took
/// 17.4 ms against 10.5.
final class Parser: @unchecked Sendable {

    enum Failure: LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let what): return "parrotflow-syrinx: \(what)"
            }
        }
    }

    static let length = 256
    static let languages: Set<String> = ["en", "fr", "es"]
    static let width = 384

    private let model: MLModel
    private let tokenizer: ScalarBPE
    private let file: MappedFile
    private let table: UnsafePointer<Float>
    private let heads: Heads
    private let bos: Int
    private let eos: Int

    init(model: MLModel, tokenizer: ScalarBPE, weights url: URL) throws {
        let file = try MappedFile(url)
        let tensors = try Tensors(file)
        guard let bos = tokenizer.id(of: "<bos>"), let eos = tokenizer.id(of: "<eos>") else {
            throw Failure.malformed("the tokenizer has no <bos> or <eos>")
        }
        self.model = model
        self.tokenizer = tokenizer
        self.file = file
        let rows = tensors.shape("embeddings")?.first ?? 0
        guard rows > 0, tokenizer.token(of: rows - 1) != nil, tokenizer.token(of: rows) == nil else {
            throw Failure.malformed("the tokenizer and the embedding table differ in size")
        }
        self.table = try tensors.pointer("embeddings", shape: [rows, Self.width])
        self.heads = try Heads(tensors)
        self.bos = bos
        self.eos = eos
    }

    /// Each word is encoded on its own, as in training.
    func subwords(_ words: Words) -> (ids: [Int], spans: [Range<Int>]) {
        var ids = [bos]
        var spans: [Range<Int>] = []
        for word in words.all {
            let piece = tokenizer.encode(word.string)
            spans.append(ids.count ..< ids.count + piece.count)
            ids += piece
        }
        ids.append(eos)
        return (ids, spans)
    }

    /// Nil means abstain: an untrained language, no words, more than 256
    /// subwords or a model error. Never truncates.
    func parse(words: Words, language: String) -> Parse? {
        guard Self.languages.contains(language), !words.all.isEmpty else { return nil }
        let (ids, spans) = subwords(words)
        guard ids.count <= Self.length, !spans.contains(where: \.isEmpty) else { return nil }
        do {
            let (g, s) = try encode(ids)
            return heads.parse(g: g, s: s, spans: spans)
        } catch {
            Log.write("parser: \(error.localizedDescription)")
            return nil
        }
    }

    private func encode(_ ids: [Int]) throws -> (g: [Float], s: [Float]) {
        let width = Self.width
        let embeddings = try MLMultiArray(
            shape: [1, NSNumber(value: Self.length), NSNumber(value: width)], dataType: .float32
        )
        let mask = try MLMultiArray(shape: [1, NSNumber(value: Self.length)], dataType: .int32)
        embeddings.withUnsafeMutableBufferPointer(ofType: Float.self) { out, _ in
            for at in 0 ..< Self.length {
                let id = at < ids.count ? ids[at] : 0
                UnsafeMutableBufferPointer(rebasing: out[at * width ..< (at + 1) * width])
                    .baseAddress?.update(from: table + id * width, count: width)
            }
        }
        mask.withUnsafeMutableBufferPointer(ofType: Int32.self) { out, _ in
            for at in 0 ..< Self.length { out[at] = at < ids.count ? 1 : 0 }
        }
        let output = try model.prediction(
            from: MLDictionaryFeatureProvider(
                dictionary: ["embeddings": embeddings, "attention_mask": mask]
            )
        )
        func rows(_ name: String) throws -> [Float] {
            guard let array = output.featureValue(for: name)?.multiArrayValue,
                  array.dataType == .float32,
                  array.shape.map(\.intValue) == [1, Self.length, width],
                  array.strides.map(\.intValue) == [Self.length * width, width, 1]
            else { throw Failure.malformed("\(name) is not a contiguous [1, 256, 384] float32") }
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(ids.count * width)) }
        }
        return (try rows("g_hidden"), try rows("s_hidden"))
    }

    /// First index of the largest value, like `numpy.argmax`.
    static func argmax<C: RandomAccessCollection>(_ values: C) -> Int where C.Element == Float, C.Index == Int {
        var best = values.startIndex
        for at in values.indices where values[at] > values[best] { best = at }
        return best - values.startIndex
    }
}

private struct Heads {
    struct Linear {
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

    let grammar: Linear
    let segments: [Range<Int>]
    let fusionT: [Float]
    let root: [Float]
    let arcDep: Linear, arcHead: Linear, relDep: Linear, relHead: Linear
    let arc: [Float]
    /// Projection width plus the bias column.
    static let arcWidth = 129, relWidth = 65
    let relWide: [Float]
    let labels: [String]
    let rootLabel: Int

    init(_ tensors: Tensors) throws {
        labels = try tensors.json([String].self, "relations")
        guard let rootLabel = labels.firstIndex(of: "root") else {
            throw Parser.Failure.malformed("no root relation")
        }
        let relations = labels.count
        struct Segment: Decodable { let key: String; let offset: Int; let size: Int; let values: [String] }
        let layout = try tensors.json([Segment].self, "inventories")
        guard layout.first?.key == "upos", layout[0].offset == 0, layout[0].values == UPOS.allCases.map(\.rawValue),
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
        segments = layout.map { $0.offset ..< $0.offset + $0.size }
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
        self.rootLabel = rootLabel
    }

    func parse(g: [Float], s: [Float], spans: [Range<Int>]) -> Parse? {
        let n = spans.count, width = Parser.width, relations = labels.count
        let logits = grammar(pool(g, spans), rows: n)
        let features = grammar.outputs
        var probs = logits
        for row in 0 ..< n {
            for segment in segments { softmax(&probs[row * features + segment.lowerBound ..< row * features + segment.upperBound]) }
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

        var words: [Parse.Word] = []
        for (index, head) in heads.enumerated() {
            let upos = Array(probs[index * features ..< index * features + UPOS.allCases.count])
            guard head != 0 else {
                words.append(Parse.Word(upos: upos, head: 0, label: "root"))
                continue
            }
            let dep = index + 1
            let r = Self.relWidth
            let wide = multiply(Array(rd[dep * r ..< (dep + 1) * r]), relWide, rows: 1, inner: r, columns: relations * r)
            var scores = (0 ..< relations).map { o in
                zip(wide[o * r ..< (o + 1) * r], rh[head * r ..< (head + 1) * r]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            }
            scores[rootLabel] = -.infinity
            words.append(Parse.Word(upos: upos, head: head, label: labels[Parser.argmax(scores)]))
        }
        return Parse(words: words)
    }

    /// Rounded through float16, as the reference does right after pooling.
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

private func transpose(_ a: [Float], rows: Int, columns: Int) -> [Float] {
    var t = [Float](repeating: 0, count: a.count)
    vDSP_mtrans(a, 1, &t, 1, vDSP_Length(columns), vDSP_Length(rows))
    return t
}

/// The 393 MB embedding table is read through this mapping. Inside the Core ML
/// model it held resident memory at 550 MB after 400 sentences; mapped, 195 MB.
private final class MappedFile {
    let base: UnsafeRawPointer
    let count: Int

    init(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Parser.Failure.malformed("cannot open \(url.lastPathComponent)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 8,
              let address = mmap(nil, Int(info.st_size), PROT_READ, MAP_PRIVATE, fd, 0),
              address != MAP_FAILED
        else { throw Parser.Failure.malformed("cannot map \(url.lastPathComponent)") }
        base = UnsafeRawPointer(address)
        count = Int(info.st_size)
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), count) }
}

/// A safetensors file: an 8-byte header length, a JSON header, then data.
private struct Tensors {
    private struct Entry: Decodable {
        let dtype: String
        let shape: [Int]
        let offsets: [Int]

        enum CodingKeys: String, CodingKey {
            case dtype, shape
            case offsets = "data_offsets"
        }
    }

    private let file: MappedFile
    private let entries: [String: Entry]
    private let metadata: [String: String]
    private let start: Int

    init(_ file: MappedFile) throws {
        let declared = UInt64(littleEndian: file.base.loadUnaligned(as: UInt64.self))
        guard declared > 0, declared <= UInt64(file.count - 8) else {
            throw Parser.Failure.malformed("a safetensors header")
        }
        let length = Int(declared)
        let header = Data(bytes: file.base + 8, count: length)
        guard var raw = try JSONSerialization.jsonObject(with: header) as? [String: Any] else {
            throw Parser.Failure.malformed("a safetensors header")
        }
        metadata = raw.removeValue(forKey: "__metadata__") as? [String: String] ?? [:]
        entries = try raw.mapValues {
            try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        self.file = file
        start = 8 + length
    }

    func shape(_ name: String) -> [Int]? { entries[name]?.shape }

    func json<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        guard let text = metadata[key] else { throw Parser.Failure.malformed("no \(key) in the metadata") }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    func pointer(_ name: String, shape: [Int]) throws -> UnsafePointer<Float> {
        guard let entry = entries[name], entry.dtype == "F32", entry.shape == shape,
              entry.offsets.count == 2, entry.offsets[0] >= 0,
              entry.offsets[1] <= file.count - start,
              entry.offsets[1] - entry.offsets[0] == shape.reduce(4, *),
              (start + entry.offsets[0]) % 4 == 0
        else { throw Parser.Failure.malformed("\(name) is not a float32 \(shape)") }
        return (file.base + start + entry.offsets[0]).assumingMemoryBound(to: Float.self)
    }

    func floats(_ name: String, shape: [Int]) throws -> [Float] {
        Array(UnsafeBufferPointer(start: try pointer(name, shape: shape), count: shape.reduce(1, *)))
    }
}
