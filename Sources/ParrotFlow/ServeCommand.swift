import Foundation

/// `--serve` keeps one process alive and answers one JSON request per line on
/// stdin with one JSON line on stdout. Each command runs the function its own
/// flag runs, so a replay pays the model load once instead of once per call.
enum ServeCommand {

    enum Request {
        case dictate(fixture: String, text: String, warm: Bool)
        case picked(word: String, term: String, sentence: String?)
        case correction(wrote: String, put: String, sentence: String?)
        case learn(heard: String, corrected: String, kind: WordKind?, sentence: String?)
        case reset

        var name: String {
            switch self {
            case .dictate: "dictate"
            case .picked: "picked"
            case .correction: "correction"
            case .learn: "learn"
            case .reset: "reset"
            }
        }
    }

    struct Malformed: Error {
        let what: String
    }

    static func run() -> Int32 {
        fflush(stdout)
        let channel = FileHandle(fileDescriptor: dup(1))
        // Anything printed from deeper code now goes to stderr, not into the protocol.
        dup2(2, 1)
        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let response = answer(line)
            let data = (try? JSONSerialization.data(
                withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes]
            )) ?? Data(#"{"error":"the response did not serialize"}"#.utf8)
            channel.write(data + Data("\n".utf8))
        }
        return 0
    }

    private static func answer(_ line: String) -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
        guard let fields = object as? [String: Any] else {
            return ["id": NSNull(), "error": "not a JSON object"]
        }
        let id = fields["id"] ?? NSNull()
        let request: Request
        do { request = try decode(fields) } catch {
            return ["id": id, "error": (error as? Malformed)?.what ?? "\(error)"]
        }
        Log.collect()
        var said: [String] = []
        let say = { (line: String) in said.append(line) }
        var response: [String: Any] = ["id": id, "cmd": request.name]
        switch request {
        case .dictate(let fixture, let text, let warm):
            if let result = PipelineCommand.dictate(path: fixture, text: text, warm: warm, say: say) {
                response["code"] = 0
                response["out"] = result.text
                var vars: [String: String] = [:]
                for path in result.scope.paths where path != "text" {
                    vars[path] = result.scope[path]?.described
                }
                response["vars"] = vars
            } else {
                response["code"] = 1
            }
        case .picked(let word, let term, let sentence):
            response["code"] = SoundGroupCommand.picked(
                word: word, term: term, sentence: sentence, dry: false, say: say
            )
        case .correction(let wrote, let put, let sentence):
            response["code"] = SoundGroupCommand.correction(
                wrote: wrote, put: put, sentence: sentence, dry: false, say: say
            )
        case .learn(let heard, let corrected, let kind, let sentence):
            response["code"] = LearnCommand.run(
                heard: heard, corrected: corrected, kind: kind, sentence: sentence, say: say
            )
        case .reset:
            response["code"] = reset(say: say)
        }
        response["said"] = said
        response["log"] = Log.takeCollected()
        return response
    }

    static func decode(_ fields: [String: Any]) throws -> Request {
        func string(_ key: String) throws -> String {
            guard let value = fields[key] as? String else {
                throw Malformed(what: "\"\(key)\" is missing or not a string")
            }
            return value
        }
        func optional(_ key: String) throws -> String? {
            guard let value = fields[key], !(value is NSNull) else { return nil }
            guard let text = value as? String else { throw Malformed(what: "\"\(key)\" is not a string") }
            return text
        }
        switch try string("cmd") {
        case "dictate":
            var warm = false
            if let value = fields["warm"] {
                guard let flag = value as? Bool else { throw Malformed(what: "\"warm\" is not a boolean") }
                warm = flag
            }
            return .dictate(fixture: try string("fixture"), text: try string("text"), warm: warm)
        case "picked":
            return .picked(word: try string("word"), term: try string("term"), sentence: try optional("in"))
        case "correction":
            return .correction(wrote: try string("wrote"), put: try string("put"), sentence: try optional("in"))
        case "learn":
            let kind = try optional("kind").map { name in
                guard let kind = WordKind(rawValue: name) else {
                    throw Malformed(what: "\"\(name)\" is not a kind")
                }
                return kind
            }
            return .learn(
                heard: try string("heard"), corrected: try string("corrected"), kind: kind,
                sentence: try optional("in")
            )
        case "reset":
            return .reset
        case let other:
            throw Malformed(what: "\"\(other)\" is not a command")
        }
    }

    private static func reset(say: (String) -> Void) -> Int32 {
        do {
            for url in [ConfigStore.vocabularyURL, TermUses.url] {
                try "terms: {}\n".write(to: url, atomically: true, encoding: .utf8)
            }
            return 0
        } catch {
            say("✗ \(error.localizedDescription)")
            return 1
        }
    }
}
