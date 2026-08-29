import Foundation

/// The byte-level BPE behind ModernBERT, read from a HuggingFace `tokenizer.json`.
///
/// Ours rather than swift-transformers. One model, one tokenizer file, no
/// package dependency: the vocabulary, the merge ranks, the GPT-2 byte
/// alphabet and the four special ids are all in that one file.
///
/// The thing to know before using it — and the thing that silently scored 0%
/// when it was got wrong — is that a word carries its leading space:
///
///     "we have to do it. That works well"
///        -> we Ġhave Ġto Ġdo Ġit . ĠThat Ġworks Ġwell
///
/// So the id for a word that follows another word is `firstID(of: " That")`,
/// 2064, and not `firstID(of: "That")`, 2773. The period after `it` is the
/// bare `.`, 15, while a period that follows a space is `Ġ.`, 964. A caller
/// asking "is there a period here" has to take the better of the two.
/// `assertBoundaryIDs` checks all of that against a real tokenization at load.
struct BPETokenizer {

    enum Failure: LocalizedError {
        case unreadable(String)
        case boundary(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let what): return "tokenizer.json: \(what)"
            case .boundary(let what): return "tokenizer.json: the boundary check failed, \(what)"
            }
        }
    }

    private let vocabulary: [String: Int]
    /// Merge rank by pair. Lower wins, which is the order the file lists them in.
    private let ranks: [Pair: Int]
    private let words: [String]

    let cls: Int
    let sep: Int
    let mask: Int
    let pad: Int

    /// 50368 — the vocabulary plus the added tokens, and the width of a
    /// logits row.
    var count: Int { words.count }

    private struct Pair: Hashable {
        let left: String
        let right: String
    }

    // MARK: - Loading

    static func load(contentsOf url: URL) throws -> BPETokenizer {
        let raw = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw Failure.unreadable("not an object")
        }
        guard let model = root["model"] as? [String: Any],
              let vocabulary = model["vocab"] as? [String: Int] else {
            throw Failure.unreadable("no model.vocab")
        }
        guard let merges = model["merges"] as? [Any] else {
            throw Failure.unreadable("no model.merges")
        }

        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (rank, entry) in merges.enumerated() {
            // Written "Ġ t" in the version this file uses, ["Ġ", "t"] in the
            // newer one. Both are in the wild for ModernBERT.
            let halves: [String]
            if let line = entry as? String {
                halves = line.components(separatedBy: " ")
            } else if let pair = entry as? [String] {
                halves = pair
            } else {
                throw Failure.unreadable("merge \(rank) is neither text nor a pair")
            }
            guard halves.count == 2 else {
                throw Failure.unreadable("merge \(rank) has \(halves.count) halves")
            }
            ranks[Pair(left: halves[0], right: halves[1])] = rank
        }

        // The added tokens sit above the vocabulary — 50280 to 50367 here —
        // and a prediction can land on any of them, so the readable side has
        // to cover them or `word(of:)` returns nothing for a real answer.
        var byID: [Int: String] = [:]
        for (token, id) in vocabulary { byID[id] = token }
        var specials: [String: Int] = [:]
        for entry in root["added_tokens"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? Int, let content = entry["content"] as? String else {
                continue
            }
            byID[id] = content
            specials[content] = id
        }
        guard let top = byID.keys.max() else { throw Failure.unreadable("empty vocabulary") }
        let words = (0...top).map { byID[$0] ?? "" }

        func special(_ name: String) throws -> Int {
            guard let id = specials[name] else {
                throw Failure.unreadable("no \(name) in added_tokens")
            }
            return id
        }

        let tokenizer = BPETokenizer(
            vocabulary: vocabulary,
            ranks: ranks,
            words: words,
            cls: try special("[CLS]"),
            sep: try special("[SEP]"),
            mask: try special("[MASK]"),
            pad: try special("[PAD]")
        )
        try tokenizer.assertBoundaryIDs()
        return tokenizer
    }

    // MARK: - Encoding

    /// Text to ids, with no `[CLS]` or `[SEP]` around it — the probe adds those.
    ///
    /// Leading and trailing spaces are part of the text and change the answer.
    /// That is the point: see the note on the type.
    func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        for chunk in Self.split(text) {
            for piece in merge(Self.toByteAlphabet(chunk)) {
                // Every piece a merge can produce is in the vocabulary: the
                // byte alphabet is, and a merge only joins two pieces that are.
                if let id = vocabulary[piece] { ids.append(id) }
            }
        }
        return ids
    }

    /// The id a caller compares against, taken from a real tokenization.
    ///
    /// Write the space: `firstID(of: " That")`, never `firstID(of: "That")`.
    func firstID(of text: String) -> Int? {
        encode(text).first
    }

    // MARK: - Reading back

    /// The id as text, with the byte alphabet undone, so `ĠDublin` reads
    /// " Dublin". The leading space is kept: it is what tells a following word
    /// from a word that continues the one before it.
    func word(of id: Int) -> String? {
        guard words.indices.contains(id) else { return nil }
        let token = words[id]
        guard !token.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(token.count)
        for character in token.unicodeScalars {
            // An added token like `[MASK]` never went through the byte
            // alphabet, so anything outside it passes through as itself.
            if let byte = Self.fromByteAlphabet[character] {
                bytes.append(byte)
            } else {
                bytes.append(contentsOf: Array(String(character).utf8))
            }
        }
        // Lossy on purpose, so `String(bytes:encoding:)` is the wrong one here:
        // a BPE piece can be half of a multi-byte character, and a prediction
        // that comes back as a replacement character is still a prediction.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - The assertion

    /// Checks the space rule against a real tokenization, not against a
    /// remembered number.
    ///
    /// A tokenizer that got the byte alphabet or the merges wrong still
    /// returns ids, and a caller comparing against the wrong id scores zero
    /// without erroring. This is what stops that shipping.
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
        // The way back, which is the half a caller reading a prediction uses.
        guard word(of: ids[5]) == ".", word(of: ids[6]) == " That" else {
            throw Failure.boundary(
                "the ids read back as \(word(of: ids[5]) ?? "") and \(word(of: ids[6]) ?? "")"
            )
        }
    }

    static let boundaryText = "we have to do it. That works well"

    /// The same four ids the assertion uses, for a caller that wants to print
    /// them. Empty if any of them will not encode, which `assertBoundaryIDs`
    /// has already refused to load past.
    var boundaryIDs: [(token: String, id: Int)] {
        [".", " .", "That", " That"].compactMap { text in
            firstID(of: text).map { (text, $0) }
        }
    }

    // MARK: - BPE

    /// Merges the highest-ranked pair until none is left, which is the
    /// reference algorithm.
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

    /// GPT-2's byte-to-unicode table. Every byte gets a printable character,
    /// so a merge never has to deal with a raw byte and the vocabulary is
    /// text. 0x20 becomes `Ġ`, which is why a leading space is visible.
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
    /// means. Letters, digits and punctuation are cut apart, and a space is
    /// kept with the word that follows it.
    private static let pattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+"
    )

    private static func split(_ text: String) -> [String] {
        // The file asks for NFC, and a decomposed é would otherwise merge
        // differently from the one in the vocabulary.
        let normalized = text.precomposedStringWithCanonicalMapping
        guard let pattern else { return [normalized] }
        let whole = NSRange(normalized.startIndex..., in: normalized)
        return pattern.matches(in: normalized, range: whole).compactMap { match in
            Range(match.range, in: normalized).map { String(normalized[$0]) }
        }
    }
}
