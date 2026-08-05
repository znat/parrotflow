import Foundation

/// The expression language a `when:` or `unless:` is written in when it is not
/// a regular expression.
///
/// A regex could ask one question — "does the text say this" — and once stages
/// could publish facts about themselves there was a second kind of question with
/// no way to spell it: `code_identifiers.count == 0`. This is that spelling.
///
/// It is a **subset of CEL**, deliberately, and the subset matters more than the
/// choice. Nothing here needs a standard: the evaluator is three hundred lines
/// and any small grammar would have run. What a standard buys is a second
/// implementation that agrees with this one without anybody writing a
/// specification — if the pipeline is ever rewritten in Python or Go, the config
/// files people have already written keep meaning what they meant, because
/// `cel-python` and `cel-go` implement the same operators. Inventing `=~` and
/// `and` instead would have cost nothing today and that agreement forever.
///
/// What is in: dotted paths, string/number/bool literals, `&&` `||` `!`, the six
/// comparisons, and four string methods — `matches`, `contains`, `startsWith`,
/// `endsWith`, all of which are CEL standard-library functions rather than
/// extensions of ours. What is out: macros (`all`, `exists`, `map`), lists,
/// maps, durations, timestamps, arithmetic. A routing condition needs none of
/// them, and each one is a type in `Scope.Value` and a rule in whatever
/// implements this next.
///
/// Two divergences from CEL worth knowing. `matches` here is ICU through
/// `NSRegularExpression`, not RE2 — so lookahead works, where a real CEL would
/// refuse it. And it is case-insensitive, because every condition in this app
/// has always been: `when: /term/` matching "Terminal" is the behaviour people
/// already have, and a language that quietly stopped doing it would break
/// configs while parsing them perfectly.
enum Condition {

    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Syntax

    indirect enum Node: Equatable {
        case literal(Scope.Value)
        /// A dotted name — `text`, `numbers.count`, `asr.confidence`.
        case path(String)
        case not(Node)
        case and(Node, Node)
        case or(Node, Node)
        case compare(Node, Comparison, Node)
        /// `receiver.method(arguments)`, the only call shape there is.
        case call(Node, String, [Node])
    }

    enum Comparison: String, Equatable {
        case equal = "=="
        case notEqual = "!="
        case less = "<"
        case lessOrEqual = "<="
        case greater = ">"
        case greaterOrEqual = ">="
    }

    /// The methods a string will answer to. Named here rather than in the
    /// evaluator so that a misspelling is caught while parsing — `startswith`
    /// is the one people write, and finding out at parse time means
    /// `--check-config` says so instead of a stage quietly never running.
    static let methods: Set<String> = ["matches", "contains", "startsWith", "endsWith"]

    // MARK: - Tokens

    private enum Token: Equatable {
        case identifier(String)
        case string(String)
        case number(Scope.Value)
        case boolean(Bool)
        case symbol(String)
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters = Array(source)
        var index = 0

        func peek(_ offset: Int = 0) -> Character? {
            let position = index + offset
            return position < characters.count ? characters[position] : nil
        }

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace { index += 1; continue }

            // A string literal. Both quote styles, because CEL takes both and a
            // pattern full of double quotes is easier to write in single ones —
            // which matters here, where most string literals are regexes.
            if character == "\"" || character == "'" {
                let quote = character
                index += 1
                var literal = ""
                var closed = false
                while index < characters.count {
                    let next = characters[index]
                    if next == "\\", let escaped = peek(1) {
                        // Only the escapes a quoted string needs. A regex is
                        // full of backslashes that mean something to the regex
                        // engine and nothing here — `\b`, `\d`, `\.` — and
                        // consuming those would leave the pattern mangled by the
                        // time it was compiled. So an unrecognised escape keeps
                        // both characters.
                        switch escaped {
                        case quote: literal.append(quote)
                        case "\\": literal.append("\\")
                        case "n": literal.append("\n")
                        case "t": literal.append("\t")
                        default: literal.append(next); literal.append(escaped)
                        }
                        index += 2
                        continue
                    }
                    if next == quote { closed = true; index += 1; break }
                    literal.append(next)
                    index += 1
                }
                guard closed else {
                    throw Failure(message: "a string is never closed — add the missing \(quote)")
                }
                tokens.append(.string(literal))
                continue
            }

            if character.isNumber {
                var literal = ""
                var isDouble = false
                while let next = peek(), next.isNumber || next == "." {
                    // A dot only continues a number when a digit follows it, so
                    // `1.5` is a double while `count.1` would end the number and
                    // let the parser complain about the rest.
                    if next == "." {
                        guard let after = peek(1), after.isNumber, !isDouble else { break }
                        isDouble = true
                    }
                    literal.append(next)
                    index += 1
                }
                if isDouble, let value = Double(literal) {
                    tokens.append(.number(.double(value)))
                } else if let value = Int(literal) {
                    tokens.append(.number(.int(value)))
                } else {
                    throw Failure(message: "\"\(literal)\" is not a number")
                }
                continue
            }

            if character.isLetter || character == "_" {
                var name = ""
                while let next = peek(), next.isLetter || next.isNumber || next == "_" {
                    name.append(next)
                    index += 1
                }
                switch name {
                case "true": tokens.append(.boolean(true))
                case "false": tokens.append(.boolean(false))
                default: tokens.append(.identifier(name))
                }
                continue
            }

            // Two-character operators before one-character ones, or `!=` lexes
            // as `!` and the parser sees a negation with nothing to negate.
            if let next = peek(1) {
                let pair = String([character, next])
                if ["&&", "||", "==", "!=", "<=", ">="].contains(pair) {
                    tokens.append(.symbol(pair))
                    index += 2
                    continue
                }
            }
            if "!<>().,".contains(character) {
                tokens.append(.symbol(String(character)))
                index += 1
                continue
            }
            // Named rather than skipped. A `&` where `&&` was meant, or the `=~`
            // somebody used to write, should say what is wrong with it.
            if character == "&" || character == "|" {
                throw Failure(
                    message: "\"\(character)\" on its own is not an operator — write"
                        + " \(character)\(character)"
                )
            }
            throw Failure(message: "\"\(character)\" is not part of this language")
        }
        return tokens
    }

    // MARK: - Parsing

    private struct Parser {
        let tokens: [Token]
        var index = 0

        var current: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func match(_ symbol: String) -> Bool {
            guard current == .symbol(symbol) else { return false }
            index += 1
            return true
        }

        mutating func expression() throws -> Node {
            var left = try conjunction()
            while match("||") {
                left = .or(left, try conjunction())
            }
            return left
        }

        mutating func conjunction() throws -> Node {
            var left = try unary()
            while match("&&") {
                left = .and(left, try unary())
            }
            return left
        }

        mutating func unary() throws -> Node {
            if match("!") { return .not(try unary()) }
            return try comparison()
        }

        mutating func comparison() throws -> Node {
            let left = try primary()
            guard case .symbol(let symbol) = current ?? .symbol(""),
                  let operation = Comparison(rawValue: symbol) else { return left }
            index += 1
            return .compare(left, operation, try primary())
        }

        mutating func primary() throws -> Node {
            guard let token = current else {
                throw Failure(message: "the expression ends where a value was expected")
            }
            index += 1

            switch token {
            case .string(let value): return .literal(.string(value))
            case .number(let value): return .literal(value)
            case .boolean(let value): return .literal(.bool(value))

            case .symbol("("):
                let inner = try expression()
                guard match(")") else {
                    throw Failure(message: "a ( is never closed")
                }
                return inner

            case .identifier(let first):
                // A dotted name, which may end in a method call. The split
                // cannot be decided until the `(` is seen: `numbers.count` is a
                // path and `text.matches` is a receiver and a method, and they
                // look identical until the next token.
                var components = [first]
                var node = Node.path(first)
                while current == .symbol(".") {
                    index += 1
                    guard case .identifier(let next)? = current else {
                        throw Failure(message: "a name is expected after \".\"")
                    }
                    index += 1
                    if current == .symbol("(") {
                        index += 1
                        guard Condition.methods.contains(next) else {
                            throw Failure(
                                message: "\"\(next)\" is not a method — have: "
                                    + Condition.methods.sorted().joined(separator: ", ")
                            )
                        }
                        var arguments: [Node] = []
                        if !match(")") {
                            repeat {
                                arguments.append(try expression())
                            } while match(",")
                            guard match(")") else {
                                throw Failure(message: "a ( is never closed")
                            }
                        }
                        guard arguments.count == 1 else {
                            throw Failure(
                                message: "\(next)() takes one argument, not \(arguments.count)"
                            )
                        }
                        node = .call(node, next, arguments)
                        // A method result is a boolean, and nothing here has a
                        // method on a boolean — so the path is finished.
                        return node
                    }
                    components.append(next)
                    node = .path(components.joined(separator: "."))
                }
                return node

            default:
                throw Failure(message: "\"\(describe(token))\" cannot start a value")
            }
        }

        func describe(_ token: Token) -> String {
            switch token {
            case .identifier(let name): return name
            case .string(let value): return "\"\(value)\""
            case .number(let value): return value.described
            case .boolean(let value): return value ? "true" : "false"
            case .symbol(let symbol): return symbol
            }
        }
    }

    /// Parsed once per condition, then kept. A pipeline runs on every transcript
    /// and re-parsing the same six conditions each time is work nobody asked
    /// for. Locked for the same reason `Pipeline.Step.expression` is: a prompt
    /// stage suspends for seconds, so a second transcript's pipeline reaches
    /// this while the first is still waiting, and a Swift Dictionary written
    /// from two threads corrupts.
    private static var cache: [String: Result<Node, Failure>] = [:]
    private static let cacheLock = NSLock()

    static func parse(_ source: String) throws -> Node {
        cacheLock.lock()
        if let cached = cache[source] {
            cacheLock.unlock()
            return try cached.get()
        }
        cacheLock.unlock()

        let outcome: Result<Node, Failure>
        do {
            var parser = Parser(tokens: try tokenize(source))
            let node = try parser.expression()
            guard parser.index == parser.tokens.count else {
                throw Failure(
                    message: "\"\(parser.describe(parser.tokens[parser.index]))\" is left over"
                        + " at the end of the expression"
                )
            }
            outcome = .success(node)
        } catch let failure as Failure {
            outcome = .failure(failure)
        }

        cacheLock.lock()
        cache[source] = outcome
        cacheLock.unlock()
        return try outcome.get()
    }

    // MARK: - Evaluating

    static func evaluate(_ source: String, in scope: Scope) throws -> Bool {
        let value = try value(of: try parse(source), in: scope)
        guard case .bool(let answer) = value else {
            throw Failure(
                message: "a condition has to be true or false, and this one is \(value.described)"
            )
        }
        return answer
    }

    private static func value(of node: Node, in scope: Scope) throws -> Scope.Value {
        switch node {
        case .literal(let value):
            return value

        case .path(let path):
            guard let found = scope[path] else {
                throw Failure(message: unknown(path, in: scope))
            }
            return found

        case .not(let inner):
            guard case .bool(let value) = try self.value(of: inner, in: scope) else {
                throw Failure(message: "! takes something true or false")
            }
            return .bool(!value)

        case .and(let left, let right):
            // Short-circuit, which is not only speed: it is what lets
            // `numbers.ran && numbers.count > 0` be written at all, since the
            // right half would throw on a stage that never ran.
            guard case .bool(let a) = try value(of: left, in: scope) else {
                throw Failure(message: "&& takes something true or false")
            }
            if !a { return .bool(false) }
            guard case .bool(let b) = try value(of: right, in: scope) else {
                throw Failure(message: "&& takes something true or false")
            }
            return .bool(b)

        case .or(let left, let right):
            guard case .bool(let a) = try value(of: left, in: scope) else {
                throw Failure(message: "|| takes something true or false")
            }
            if a { return .bool(true) }
            guard case .bool(let b) = try value(of: right, in: scope) else {
                throw Failure(message: "|| takes something true or false")
            }
            return .bool(b)

        case .compare(let left, let operation, let right):
            return .bool(try compare(
                try value(of: left, in: scope), operation, try value(of: right, in: scope)
            ))

        case .call(let receiver, let method, let arguments):
            guard case .string(let subject) = try value(of: receiver, in: scope) else {
                throw Failure(message: "\(method)() only works on text")
            }
            guard case .string(let argument) = try value(of: arguments[0], in: scope) else {
                throw Failure(message: "\(method)() takes a string")
            }
            return .bool(try apply(method, subject, argument))
        }
    }

    private static func compare(
        _ left: Scope.Value, _ operation: Comparison, _ right: Scope.Value
    ) throws -> Bool {
        // Numbers first, so an int and a double compare as the numbers they
        // are. A script returning 1 and one returning 1.0 have said the same
        // thing, and a condition that disagreed would be reporting the script's
        // JSON encoder rather than its answer.
        if let a = left.asDouble, let b = right.asDouble {
            switch operation {
            case .equal: return a == b
            case .notEqual: return a != b
            case .less: return a < b
            case .lessOrEqual: return a <= b
            case .greater: return a > b
            case .greaterOrEqual: return a >= b
            }
        }
        if case .string(let a) = left, case .string(let b) = right {
            switch operation {
            case .equal: return a == b
            case .notEqual: return a != b
            case .less: return a < b
            case .lessOrEqual: return a <= b
            case .greater: return a > b
            case .greaterOrEqual: return a >= b
            }
        }
        if case .bool(let a) = left, case .bool(let b) = right {
            switch operation {
            case .equal: return a == b
            case .notEqual: return a != b
            default:
                throw Failure(message: "true and false can only be compared with == and !=")
            }
        }
        throw Failure(
            message: "\(left.described) and \(right.described) are different kinds of thing"
                + " and cannot be compared"
        )
    }

    private static func apply(_ method: String, _ subject: String, _ argument: String) throws -> Bool {
        switch method {
        case "contains":
            return subject.range(of: argument, options: .caseInsensitive) != nil
        case "startsWith":
            return subject.lowercased().hasPrefix(argument.lowercased())
        case "endsWith":
            return subject.lowercased().hasSuffix(argument.lowercased())
        case "matches":
            guard let expression = try? NSRegularExpression(
                pattern: argument, options: [.caseInsensitive]
            ) else {
                throw Failure(message: "\"\(argument)\" is not a valid regular expression")
            }
            return expression.firstMatch(
                in: subject, range: NSRange(subject.startIndex..., in: subject)
            ) != nil
        default:
            throw Failure(message: "\"\(method)\" is not a method")
        }
    }

    // MARK: - Diagnostics

    /// Why a name resolved to nothing, said in the way most likely to be the
    /// actual mistake.
    ///
    /// Three of them, and the order is by likelihood rather than by severity.
    /// The first is the migration: `when: genre` used to mean "the word genre
    /// appears", and now parses as a variable nobody defined. Reading it as
    /// false would have been the silent failure this whole design refuses, and
    /// reading it as an error is only useful if the error says what to write
    /// instead.
    private static func unknown(_ path: String, in scope: Scope) -> String {
        if !path.contains(".") {
            return "\"\(path)\" is not a variable. If you meant the word \"\(path)\" in the"
                + " text, write it as a pattern: /\(path)/"
        }
        let namespace = String(path.prefix(while: { $0 != "." }))
        let known = Set(scope.paths.compactMap { path -> String? in
            guard path.contains(".") else { return nil }
            return String(path.prefix(while: { $0 != "." }))
        })
        if !known.contains(namespace) && !Scope.reserved.contains(namespace) {
            return "no stage called \"\(namespace)\" has run yet, so \"\(path)\" has no value."
                + " A condition can only read a stage above it in the pipeline."
        }
        let inside = scope.namespace(namespace).keys.sorted()
        return "\"\(path)\" is not something \"\(namespace)\" reports"
            + (inside.isEmpty ? "" : " — it reports: \(inside.joined(separator: ", "))")
    }

    /// Every name an expression reads, for the check that runs before anything
    /// does. `validate()` uses it to refuse a condition that reads a stage
    /// declared below it, which is the failure no runtime error can catch in
    /// time: by then the transcript is already halfway through the pipeline.
    static func roots(of source: String) -> Set<String> {
        guard let node = try? parse(source) else { return [] }
        var found: Set<String> = []
        collect(node, into: &found)
        return found
    }

    private static func collect(_ node: Node, into found: inout Set<String>) {
        switch node {
        case .literal:
            return
        case .path(let path):
            found.insert(path)
        case .not(let inner):
            collect(inner, into: &found)
        case .and(let a, let b), .or(let a, let b):
            collect(a, into: &found); collect(b, into: &found)
        case .compare(let a, _, let b):
            collect(a, into: &found); collect(b, into: &found)
        case .call(let receiver, _, let arguments):
            collect(receiver, into: &found)
            for argument in arguments { collect(argument, into: &found) }
        }
    }
}
