import Foundation

/// One dictation's timeline, as something you can read in a terminal, paste
/// into an issue, or diff against yesterday's.
///
/// The last of those is why this exists rather than a picture. A flamegraph
/// answers "where did the time go" and nothing else; two of these run through
/// `diff` answer "did that change make it slower", which is the question a
/// timeline is usually opened for.
///
/// Reads the spans as they come off `spans.jsonl` — untyped, because both
/// callers here already hold parsed JSON and giving them a type to decode into
/// would mean maintaining the same shape twice.
enum TraceText {

    /// How wide the bars are. Narrow enough to survive a paste into a GitHub
    /// comment, which wraps at about 90 columns with the name column in front.
    static let width = 44

    /// A parent chain longer than this is a cycle, which cannot happen from a
    /// collector that only ever nests a stage — and must not hang if it does.
    private static let maxDepth = 8

    /// - Parameter notes: what each step found out. Off for anything leaving
    ///   the machine: a note can quote a word — `sarah -> Sarah` — and nothing
    ///   here can tell those from the ones that cannot.
    static func render(_ record: [String: Any], notes: Bool = true) -> String? {
        guard let spans = record["spans"] as? [[String: Any]], !spans.isEmpty else { return nil }

        let ordered = spans.sorted {
            let left = $0["at"] as? Double ?? 0, right = $1["at"] as? Double ?? 0
            if left != right { return left < right }
            // A parent opens at the same moment as its first child and lasts
            // longer, so the longer one goes above.
            return ($0["dur"] as? Double ?? 0) > ($1["dur"] as? Double ?? 0)
        }
        let total = ordered.map { ($0["at"] as? Double ?? 0) + ($0["dur"] as? Double ?? 0) }.max() ?? 0
        guard total > 0 else { return nil }

        var byID: [Int: [String: Any]] = [:]
        for span in ordered { if let id = span["id"] as? Int { byID[id] = span } }

        var lines: [String] = []
        var head = record["t0"] as? String ?? ""
        if let app = (record["app"] as? [String: Any])?["name"] as? String, notes {
            head += "   \(app)"
        }
        lines.append(String(format: "%@   %.3fs", head, total))
        lines.append("")

        for span in ordered {
            let name = span["name"] as? String ?? "?"
            let at = span["at"] as? Double ?? 0
            let duration = span["dur"] as? Double ?? 0

            let indent = String(repeating: "  ", count: depth(of: span, in: byID))
            let label = String("  \(indent)\(name)".prefix(32)).padding(
                toLength: 32, withPad: " ", startingAt: 0
            )
            // At least one block for anything that ran at all: a step that took
            // no measurable time still happened, and an empty row reads as one
            // that did not.
            let start = min(width - 1, Int(at / total * Double(width)))
            let length = max(1, min(width - start, Int(duration / total * Double(width))))
            let bar = String(repeating: " ", count: start)
                + String(repeating: "█", count: length)

            var line = label + String(format: "%7.3fs  ", duration)
                + bar.padding(toLength: width, withPad: " ", startingAt: 0)
            if notes, let note = span["note"] as? String, !note.isEmpty { line += "  \(note)" }
            lines.append(line.replacingOccurrences(
                of: " +$", with: "", options: .regularExpression
            ))
        }

        if notes, let final = record["final"] as? String, !final.isEmpty {
            lines.append("")
            lines.append("  \(final)")
        }
        return lines.joined(separator: "\n")
    }

    /// How deep a span sits, by walking its parents.
    private static func depth(of span: [String: Any], in byID: [Int: [String: Any]]) -> Int {
        var found = 0
        var current = span
        while found < maxDepth, let parent = current["parent"] as? Int, let up = byID[parent] {
            current = up
            found += 1
        }
        return found
    }
}
