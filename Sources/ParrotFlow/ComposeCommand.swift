import Foundation

/// `--compose "<template>" [name=value ...]` — prints a prompt with its
/// placeholders filled, and applies nothing.
///
/// The whole point is that no model is involved. What a prompt *says* after the
/// scope is folded into it is decided before any model sees it, and it is the
/// half that can be scored exactly — which is what scripts/check-compose.sh
/// does. `--prompt` exercises the other half and needs Ollama running.
///
/// Values are typed by how they read, because that is what a script writing a
/// case file can express: `3` is an int, `true` is a bool, everything else is a
/// string. A prompt renders all four the same way, so the distinction only shows
/// up if a case ever needs it to.
enum ComposeCommand {

    static func run(template: String, assignments: [String]) -> Int32 {
        var scope = Scope()
        for assignment in assignments {
            guard let split = assignment.firstIndex(of: "=") else {
                print("✗ expected name=value, got \"\(assignment)\"")
                return 2
            }
            let name = String(assignment[assignment.startIndex..<split])
            let raw = String(assignment[assignment.index(after: split)...])
            scope.set(name, value(of: expanded(raw)))
        }
        print(Template.fill(expanded(template), from: scope), terminator: "")
        return 0
    }

    /// `\n` on a command line is two characters. A case file has to hold
    /// multi-line templates on one line, and the paragraph rule is the thing
    /// being tested, so the escape is not a convenience here.
    static func expanded(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
    }

    private static func value(of raw: String) -> Scope.Value {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if let int = Int(raw) { return .int(int) }
        if let double = Double(raw) { return .double(double) }
        return .string(raw)
    }
}
