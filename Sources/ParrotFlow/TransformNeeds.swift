import Foundation
import Yams

extension Config.Transform {
    /// `returns:`, `parse:` and `readings:` as one place wrote them: a config
    /// entry, or a script's `parrotflow:` line. Nil is a key not written there.
    struct Needs: Equatable {
        var returnsJSON: Bool?
        var parse: Parse?
        var readings: Bool?

        enum Parse: Int, Comparable {
            case off, tree, vectors

            static func < (a: Parse, b: Parse) -> Bool { a.rawValue < b.rawValue }

            var spelled: String { ["false", "true", "vectors"][rawValue] }
        }

        struct Refused: Error {
            let why: String
        }

        static let keys = ["returns", "parse", "readings"]

        /// Each key written here, as the config spells its value.
        var spelled: [String: String] {
            var out: [String: String] = [:]
            if let returnsJSON { out["returns"] = returnsJSON ? "json" : "text" }
            if let parse { out["parse"] = parse.spelled }
            if let readings { out["readings"] = String(readings) }
            return out
        }

        /// Each key written here that asks for less than `declared` does.
        func shortfalls(against declared: Needs) -> [(written: String, declared: String)] {
            var out: [(String, String)] = []
            if returnsJSON == false, declared.returnsJSON == true {
                out.append(("returns: text", "returns: json"))
            }
            if let parse, let wanted = declared.parse, parse < wanted {
                out.append(("parse: \(parse.spelled)", "parse: \(wanted.spelled)"))
            }
            if readings == false, declared.readings == true {
                out.append(("readings: false", "readings: true"))
            }
            return out
        }

        /// `# parrotflow: {returns: json}`, `// parrotflow: {…}`: any comment
        /// marker of up to three characters.
        nonisolated(unsafe) static let line = #/^\s*\S{1,3}\s*parrotflow:(.*)$/#

        /// The `parrotflow:` line in the first ten lines of `file`, or no
        /// keys when there is none. A compiled program has none, and writes its
        /// keys in the config instead.
        static func declared(in file: URL) throws -> Needs {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return Needs() }
            defer { try? handle.close() }
            let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
            let found = head.split(separator: "\n", omittingEmptySubsequences: false).prefix(10)
                .lazy.compactMap { $0.firstMatch(of: line)?.1 }.first
            guard let found else { return Needs() }
            guard let open = found.firstIndex(of: "{"), let close = found.lastIndex(of: "}"),
                  open < close,
                  let node = try? Yams.compose(yaml: String(found[open...close])),
                  let mapping = node.mapping
            else {
                throw Refused(why: "is not a mapping like `{returns: json, parse: true}`")
            }
            if let unknown = mapping.keys.compactMap(\.string).first(where: { !keys.contains($0) }) {
                throw Refused(why: "names `\(unknown)`, which is not returns, parse or readings")
            }
            let needs = try YAMLDecoder().decode(Needs.self, from: node)
            if needs.returnsJSON != true, (needs.parse ?? .off) != .off || needs.readings == true {
                throw Refused(why: "asks for the parse or the readings without `returns: json`")
            }
            return needs
        }
    }
}

extension Config.Transform.Needs: Decodable {
    private enum CodingKeys: String, CodingKey {
        case returns, parse, readings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func written(_ key: CodingKeys) -> (raw: String, word: String)? {
            guard c.contains(key), !((try? c.decodeNil(forKey: key)) ?? false) else { return nil }
            let raw = (try? c.decode(Bool.self, forKey: key)).map { $0 ? "true" : "false" }
                ?? (try? c.decode(String.self, forKey: key)) ?? ""
            return (raw, raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        if let (raw, word) = written(.returns) {
            guard word == "json" || word == "text" else {
                throw Refused(why: "has `returns: \(raw)`, which is not json or text")
            }
            returnsJSON = word == "json"
        }
        if let (raw, word) = written(.parse) {
            switch word {
            case "true": parse = .tree
            case "false": parse = .off
            case "vectors": parse = .vectors
            default: throw Refused(why: "has `parse: \(raw)`, which is not true, false or vectors")
            }
        }
        if let (raw, word) = written(.readings) {
            guard word == "true" || word == "false" else {
                throw Refused(why: "has `readings: \(raw)`, which is not true or false")
            }
            readings = word == "true"
        }
    }
}
