import Foundation

/// mmBERT-small's `tokenizer.json`, encoded the way HuggingFace `tokenizers`
/// encodes it: added tokens matched on the raw text, `▁` for a space, a split
/// before every `▁`, then byte-fallback BPE over Unicode scalars.
///
/// Every key is kept as UTF-8 bytes. Swift `String` equality is canonical, so a
/// `String`-keyed reader merges `cafe` + U+0301 into a key the vocab does not
/// hold, and `JSONSerialization` keeps 255,994 of the 256,000 keys, losing `#`
/// and `\r`.
struct ScalarBPE: Sendable {

    enum Failure: LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let what): return "tokenizer.json: \(what)"
            }
        }
    }

    private struct Merge {
        let rank: Int32
        let id: Int32
    }

    private struct Added {
        let scalars: [Unicode.Scalar]
        let id: Int32
    }

    private let vocab: [[UInt8]: Int32]
    private let tokens: [[UInt8]]
    private let merges: [UInt64: Merge]
    private let added: [Unicode.Scalar: [Added]]
    private let byteIDs: [Int32]
    private let metaspace: Int32

    init(contentsOf url: URL) throws {
        var json = JSONBytes(bytes: [UInt8](try Data(contentsOf: url)))
        var vocab: [[UInt8]: Int32] = [:]
        var merges: [UInt64: Merge] = [:]
        var added: [(key: [UInt8], token: Added)] = []
        var rank: Int32 = 0

        try json.object { key, json in
            switch String(bytes: key, encoding: .utf8) {
            case "added_tokens":
                try json.array { json in
                    var content: [UInt8]?
                    var id: Int32?
                    try json.object { key, json in
                        switch String(bytes: key, encoding: .utf8) {
                        case "content": content = try json.string()
                        case "id": id = try json.integer()
                        default: try json.skip()
                        }
                    }
                    guard let content, let id, let text = String(bytes: content, encoding: .utf8)
                    else { throw Failure.malformed("an added token") }
                    added.append((content, Added(scalars: Array(text.unicodeScalars), id: id)))
                }
            case "model":
                try json.object { key, json in
                    switch String(bytes: key, encoding: .utf8) {
                    case "vocab":
                        try json.object { key, json in
                            guard vocab.updateValue(try json.integer(), forKey: key) == nil
                            else { throw Failure.malformed("a repeated vocab key") }
                        }
                    case "merges":
                        guard !vocab.isEmpty else { throw Failure.malformed("merges before vocab") }
                        try json.array { json in
                            let pair = try json.string()
                            guard let space = pair.firstIndex(of: UInt8(ascii: " ")) else {
                                throw Failure.malformed("a merge with no space")
                            }
                            let first = Array(pair[..<space]), second = Array(pair[(space + 1)...])
                            guard let left = vocab[first], let right = vocab[second],
                                  let merged = vocab[first + second]
                            else { throw Failure.malformed("a merge outside the vocab") }
                            merges[Self.pair(left, right)] = Merge(rank: rank, id: merged)
                            rank += 1
                        }
                    default: try json.skip()
                    }
                }
            default: try json.skip()
            }
        }
        try json.end()

        guard let metaspace = vocab[Array("\u{2581}".utf8)], let unknown = vocab[Array("<unk>".utf8)]
        else { throw Failure.malformed("no ▁ or <unk>") }
        guard Set(vocab.values).count == vocab.count else { throw Failure.malformed("a repeated id") }
        guard added.allSatisfy({ vocab[$0.key] == $0.token.id }) else {
            throw Failure.malformed("an added token outside the vocab")
        }
        var tokens = [[UInt8]](repeating: [], count: vocab.count)
        for (key, id) in vocab {
            guard tokens.indices.contains(Int(id)) else { throw Failure.malformed("id \(id)") }
            tokens[Int(id)] = key
        }
        self.vocab = vocab
        self.tokens = tokens
        self.merges = merges
        self.added = Dictionary(grouping: added.map(\.token).filter { !$0.scalars.isEmpty }) { $0.scalars[0] }
            .mapValues { $0.sorted { $0.scalars.count > $1.scalars.count } }
        // <0x09> is not in this vocab. A tab never falls back: `\t` is a token.
        self.byteIDs = (0 ..< 256).map { vocab[Array(String(format: "<0x%02X>", $0).utf8)] ?? unknown }
        self.metaspace = metaspace
    }

    func id(of token: String) -> Int? {
        vocab[Array(token.utf8)].map(Int.init)
    }

    func token(of id: Int) -> String? {
        tokens.indices.contains(id) ? String(bytes: tokens[id], encoding: .utf8) : nil
    }

    func encode(_ text: String) -> [Int] {
        let scalars = Array(text.unicodeScalars)
        var ids: [Int] = []
        var word: [Int32] = []
        var at = 0
        while at < scalars.count {
            let scalar = scalars[at]
            if let token = added[scalar]?.first(where: { scalars[at...].starts(with: $0.scalars) }) {
                merge(&word, into: &ids)
                ids.append(Int(token.id))
                at += token.scalars.count
                continue
            }
            let space = scalar == " " || scalar == "\u{2581}"
            if space { merge(&word, into: &ids) }
            if space || word.isEmpty { word.append(metaspace) }
            if !space {
                let bytes = Array(scalar.utf8)
                if let id = vocab[bytes] { word.append(id) } else { word += bytes.map { byteIDs[Int($0)] } }
            }
            at += 1
        }
        merge(&word, into: &ids)
        return ids
    }

    private func merge(_ word: inout [Int32], into ids: inout [Int]) {
        while word.count > 1 {
            var best: (merge: Merge, at: Int)?
            for at in 0 ..< word.count - 1 {
                if let merge = merges[Self.pair(word[at], word[at + 1])],
                   merge.rank < best?.merge.rank ?? .max {
                    best = (merge, at)
                }
            }
            guard let best else { break }
            word[best.at] = best.merge.id
            word.remove(at: best.at + 1)
        }
        ids += word.map(Int.init)
        word.removeAll(keepingCapacity: true)
    }

    private static func pair(_ left: Int32, _ right: Int32) -> UInt64 {
        UInt64(UInt32(left)) << 32 | UInt64(UInt32(right))
    }
}

private struct JSONBytes {
    let bytes: [UInt8]
    var at = 0

    mutating func object(_ member: ([UInt8], inout JSONBytes) throws -> Void) throws {
        try expect("{")
        if try peek() == UInt8(ascii: "}") { at += 1; return }
        repeat {
            let key = try string()
            try expect(":")
            try member(key, &self)
        } while try more(closing: "}")
    }

    mutating func array(_ element: (inout JSONBytes) throws -> Void) throws {
        try expect("[")
        if try peek() == UInt8(ascii: "]") { at += 1; return }
        repeat {
            try element(&self)
        } while try more(closing: "]")
    }

    mutating func string() throws -> [UInt8] {
        try expect("\"")
        var out: [UInt8] = []
        while true {
            let byte = try take()
            switch byte {
            case UInt8(ascii: "\""):
                return out
            case UInt8(ascii: "\\"):
                switch try take() {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(bytes[at - 1])
                case UInt8(ascii: "u"):
                    var value = try hex4()
                    if (0xD800 ..< 0xDC00).contains(value) {
                        guard try take() == UInt8(ascii: "\\"), try take() == UInt8(ascii: "u"),
                              case let low = try hex4(), (0xDC00 ..< 0xE000).contains(low)
                        else {
                            throw ScalarBPE.Failure.malformed("\\u escape at byte \(at)")
                        }
                        value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(value) else {
                        throw ScalarBPE.Failure.malformed("\\u escape at byte \(at)")
                    }
                    out += Array(scalar.utf8)
                default: throw ScalarBPE.Failure.malformed("an escape at byte \(at - 1)")
                }
            default:
                out.append(byte)
            }
        }
    }

    mutating func integer() throws -> Int32 {
        _ = try peek()
        let start = at
        var value: Int32 = 0
        while at < bytes.count, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[at]) {
            let digit = Int32(bytes[at] - UInt8(ascii: "0"))
            guard value <= (Int32.max - digit) / 10 else {
                throw ScalarBPE.Failure.malformed("a number at byte \(start)")
            }
            value = value * 10 + digit
            at += 1
        }
        guard at > start else { throw ScalarBPE.Failure.malformed("a number at byte \(start)") }
        return value
    }

    mutating func skip() throws {
        switch try peek() {
        case UInt8(ascii: "\""): _ = try string()
        case UInt8(ascii: "{"): try object { _, json in try json.skip() }
        case UInt8(ascii: "["): try array { json in try json.skip() }
        default:
            while at < bytes.count, !Self.ends(bytes[at]) { at += 1 }
        }
    }

    mutating func end() throws {
        while at < bytes.count, Self.blank(bytes[at]) { at += 1 }
        guard at == bytes.count else { throw ScalarBPE.Failure.malformed("bytes after the end at \(at)") }
    }

    private static func ends(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") || blank(byte)
    }

    private static func blank(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    private mutating func peek() throws -> UInt8 {
        while at < bytes.count, Self.blank(bytes[at]) { at += 1 }
        guard at < bytes.count else { throw ScalarBPE.Failure.malformed("it ends early") }
        return bytes[at]
    }

    private mutating func take() throws -> UInt8 {
        guard at < bytes.count else { throw ScalarBPE.Failure.malformed("it ends early") }
        defer { at += 1 }
        return bytes[at]
    }

    private mutating func expect(_ character: Unicode.Scalar) throws {
        guard try peek() == UInt8(ascii: character) else {
            throw ScalarBPE.Failure.malformed("no \(character) at byte \(at)")
        }
        at += 1
    }

    private mutating func more(closing: Unicode.Scalar) throws -> Bool {
        let byte = try peek()
        at += 1
        if byte == UInt8(ascii: ",") { return true }
        if byte == UInt8(ascii: closing) { return false }
        throw ScalarBPE.Failure.malformed("no , or \(closing) at byte \(at - 1)")
    }

    private mutating func hex4() throws -> UInt32 {
        guard at + 4 <= bytes.count,
              let digits = String(bytes: bytes[at ..< at + 4], encoding: .utf8),
              let value = UInt32(digits, radix: 16)
        else { throw ScalarBPE.Failure.malformed("\\u escape at byte \(at)") }
        at += 4
        return value
    }
}
