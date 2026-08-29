import Foundation

/// The byte-level BPE behind ModernBERT, read from a HuggingFace `tokenizer.json`.
///
/// Ours rather than swift-transformers: one model, one file, no package
/// dependency. Encode only — the vocabulary, the merge ranks, the GPT-2 byte
/// alphabet and the added tokens all come out of that one file.
///
/// The thing to know before comparing against an id is that a word carries its
/// leading space:
///
///     "we have to do it. That works well"
///       -> we Ġhave Ġto Ġdo Ġit . ĠThat Ġworks Ġwell
///
/// So the word after a boundary is `firstID(of: " That")`, 2064, and never
/// `firstID(of: "That")`, 2773. The period is the bare `.`, 15, not `Ġ.`, 964.
/// `assertBoundaryIDs` checks that against a real tokenization at load, because
/// getting it wrong returns numbers rather than an error.
struct BPETokenizer: Sendable {

    enum Failure: LocalizedError {
        case unreadable(String)
        case boundary(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let what), .boundary(let what): return "tokenizer.json: \(what)"
            }
        }
    }

    private struct Pair: Hashable {
        let left: String
        let right: String
    }

    private struct Added {
        let content: String
        let id: Int
        /// `[MASK]` alone. It eats the space in front of it, so
        /// `"it [MASK] that"` is `it` `[MASK]` `Ġthat` and never a stray `Ġ`.
        let lstrip: Bool
    }

    private let vocabulary: [String: Int]
    /// Merge rank by pair. Lower wins, which is the order the file lists them in.
    private let ranks: [Pair: Int]
    /// Added tokens by their first character, longest content first.
    private let added: [Character: [Added]]
    /// Token by id, for reading a prediction back.
    private let words: [String]

    let cls: Int
    let sep: Int
    let mask: Int
    let pad: Int

    /// 50368 here: the vocabulary plus the added tokens above it, which is the
    /// width of a logits row.
    var count: Int { words.count }

    // MARK: - Loading

    static func load(contentsOf url: URL) throws -> BPETokenizer {
        let raw = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let vocabulary = model["vocab"] as? [String: Int],
              let merges = model["merges"] as? [Any] else {
            throw Failure.unreadable("no model.vocab or model.merges")
        }

        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (rank, entry) in merges.enumerated() {
            // Written "Ġ t" in the version this file uses, ["Ġ", "t"] in the
            // newer one. Both are in the wild for ModernBERT.
            let halves = (entry as? String).map { $0.components(separatedBy: " ") }
                ?? (entry as? [String]) ?? []
            guard halves.count == 2 else {
                throw Failure.unreadable("merge \(rank) is not a pair")
            }
            ranks[Pair(left: halves[0], right: halves[1])] = rank
        }

        var byID: [Int: String] = [:]
        for (token, id) in vocabulary { byID[id] = token }

        var added: [Character: [Added]] = [:]
        var byName: [String: Int] = [:]
        for entry in root["added_tokens"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? Int,
                  let content = entry["content"] as? String,
                  let first = content.first else { continue }
            byName[content] = id
            // The added tokens sit above the vocabulary, 50280 to 50367 here,
            // and a prediction can land on any of them.
            byID[id] = content
            added[first, default: []].append(
                Added(content: content, id: id, lstrip: entry["lstrip"] as? Bool ?? false)
            )
        }
        guard let top = byID.keys.max() else { throw Failure.unreadable("empty vocabulary") }
        // Longest first, so "   " wins over "  " at the same position. That is
        // what the reference matcher does, and this file has runs of 2 to 24
        // spaces as tokens of their own.
        for key in added.keys {
            added[key]?.sort { $0.content.count > $1.content.count }
        }

        func special(_ name: String) throws -> Int {
            guard let id = byName[name] else { throw Failure.unreadable("no \(name)") }
            return id
        }

        let tokenizer = BPETokenizer(
            vocabulary: vocabulary,
            ranks: ranks,
            added: added,
            words: (0...top).map { byID[$0] ?? "" },
            cls: try special("[CLS]"),
            sep: try special("[SEP]"),
            mask: try special("[MASK]"),
            pad: try special("[PAD]")
        )
        try tokenizer.assertBoundaryIDs()
        return tokenizer
    }

    // MARK: - Encoding

    /// Text to ids, with no `[CLS]` or `[SEP]` around it — the caller adds those.
    ///
    /// Leading and trailing spaces are part of the text and change the answer.
    /// That is the point: see the note on the type.
    func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        // The file asks for NFC. A decomposed é merges differently from the
        // one in the vocabulary.
        let normalized = text.precomposedStringWithCanonicalMapping
        var plain = ""
        var index = normalized.startIndex
        while index < normalized.endIndex {
            if let token = match(normalized, at: index) {
                if token.lstrip {
                    while plain.last?.isWhitespace == true { plain.removeLast() }
                }
                append(plain, to: &ids)
                plain = ""
                ids.append(token.id)
                index = normalized.index(index, offsetBy: token.content.count)
            } else {
                plain.append(normalized[index])
                index = normalized.index(after: index)
            }
        }
        append(plain, to: &ids)
        return ids
    }

    /// The id a caller compares against, taken from a real tokenization.
    ///
    /// Write the space: `firstID(of: " That")`, never `firstID(of: "That")`.
    func firstID(of text: String) -> Int? {
        encode(text).first
    }

    /// The id as text, with the byte alphabet undone, so `ĠDublin` reads
    /// " Dublin". The leading space is kept: it is what tells a following word
    /// from a piece that continues the word before it. Lossy, because one BPE
    /// piece can be half of a multi-byte character.
    func word(of id: Int) -> String? {
        guard words.indices.contains(id), !words[id].isEmpty else { return nil }
        var bytes: [UInt8] = []
        for scalar in words[id].unicodeScalars {
            // An added token like `[MASK]` never went through the byte
            // alphabet, so anything outside it passes through as itself.
            if let byte = Self.fromByteAlphabet[scalar] {
                bytes.append(byte)
            } else {
                bytes.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        // Lossy on purpose. A failable initializer returns nil for the pieces
        // that are half a character, and those still have to print.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }

    private func match(_ text: String, at index: String.Index) -> Added? {
        added[text[index]]?.first { text[index...].hasPrefix($0.content) }
    }

    /// One stretch of ordinary text, split then merged. An added token ends a
    /// stretch, so the word after `[MASK]` starts bare, exactly as the
    /// reference does it.
    private func append(_ text: String, to ids: inout [Int]) {
        for chunk in Self.split(text) {
            for piece in merge(Self.toByteAlphabet(chunk)) {
                // Every piece a merge can reach is in the vocabulary: the byte
                // alphabet is, and a merge only joins two pieces that are.
                if let id = vocabulary[piece] { ids.append(id) }
            }
        }
    }

    // MARK: - The assertion

    /// Checks the space rule against a real tokenization, not against a
    /// remembered number.
    ///
    /// A tokenizer with the byte alphabet or the merges wrong still returns
    /// ids, and a caller comparing against the wrong id scores zero without
    /// erroring. This is what stops that shipping.
    func assertBoundaryIDs() throws {
        let ids = encode(Self.boundaryText)
        guard let period = firstID(of: "."),
              let spacedPeriod = firstID(of: " ."),
              let following = firstID(of: " That"),
              let bare = firstID(of: "That") else {
            throw Failure.boundary("the boundary tokens do not encode")
        }
        guard ids.count == 9 else {
            throw Failure.boundary("\(Self.boundaryText.debugDescription) is \(ids.count) ids, want 9")
        }
        guard ids[5] == period else {
            throw Failure.boundary("the period is \(ids[5]), and \".\" is \(period)")
        }
        guard ids[6] == following else {
            throw Failure.boundary("the word after it is \(ids[6]), and \" That\" is \(following)")
        }
        guard following != bare, period != spacedPeriod else {
            throw Failure.boundary("the space makes no difference, so the byte alphabet is wrong")
        }
    }

    static let boundaryText = "we have to do it. That works well"

    /// The four ids the assertion just checked, for a caller that prints them.
    var boundaryIDs: [(token: String, id: Int)] {
        [".", " .", "That", " That"].compactMap { text in
            firstID(of: text).map { (text, $0) }
        }
    }

    // MARK: - BPE

    /// Merges the best-ranked pair until none is left, which is the reference
    /// algorithm.
    private func merge(_ word: String) -> [String] {
        var pieces = word.unicodeScalars.map { String($0) }
        while pieces.count > 1 {
            var best = Int.max
            var at = -1
            for index in 0..<(pieces.count - 1) {
                let rank = ranks[Pair(left: pieces[index], right: pieces[index + 1])]
                if let rank, rank < best {
                    best = rank
                    at = index
                }
            }
            guard at >= 0 else { break }
            pieces.replaceSubrange(at...(at + 1), with: [pieces[at] + pieces[at + 1]])
        }
        return pieces
    }

    // MARK: - The byte alphabet

    /// GPT-2's byte-to-unicode table: every byte gets a printable character, so
    /// the vocabulary is text and a merge never sees a raw byte. 0x20 becomes
    /// `Ġ`, which is what makes a leading space visible.
    private static let alphabet: [Character] = {
        let printable = Set(Array(0x21...0x7E) + Array(0xA1...0xAC) + Array(0xAE...0xFF))
        var table = [Character](repeating: " ", count: 256)
        var next = 256
        for byte in 0..<256 {
            var scalar = byte
            if !printable.contains(byte) {
                scalar = next
                next += 1
            }
            table[byte] = Character(UnicodeScalar(UInt32(scalar)) ?? " ")
        }
        return table
    }()

    private static let fromByteAlphabet: [Unicode.Scalar: UInt8] = {
        var back: [Unicode.Scalar: UInt8] = [:]
        for (byte, character) in alphabet.enumerated() {
            for scalar in character.unicodeScalars { back[scalar] = UInt8(byte) }
        }
        return back
    }()

    private static func toByteAlphabet(_ text: String) -> String {
        String(text.utf8.map { alphabet[Int($0)] })
    }

    // MARK: - The pre-tokenizer

    /// GPT-2's split, which is what `"pre_tokenizer": {"type": "ByteLevel"}`
    /// means. Letters, digits and punctuation are cut apart, and a space stays
    /// with the word after it.
    private static let pattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+"
    )

    private static func split(_ text: String) -> [String] {
        guard let pattern, !text.isEmpty else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: whole).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
